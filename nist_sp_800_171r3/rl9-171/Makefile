# NIST SP 800-171r3 overlay for Rocky Linux 9

SHELL := /bin/bash
PDF    := NIST.SP.800-171r3.pdf
# The mirror the ISO and the installer use: NIST_ROCKY_MIRROR replaces it (a
# nearer or proxied one). NIST_CURL_OPTS adds curl options - -4 where this
# host's IPv6 route carries nothing (tools/diagnose-lab-net.sh says so).
ROCKY_MIRROR := $(or $(NIST_ROCKY_MIRROR),https://dl.rockylinux.org/pub/rocky/9)
ISO_URL := $(ROCKY_MIRROR)/isos/x86_64/Rocky-9.8-x86_64-boot.iso
ISO     := iso/Rocky-9.8-x86_64-boot.iso

# Every target runs in the control-plane container (TASKS C2): run outside
# it, make runs again inside, through ./nist, with the same goals - so a host
# needs podman or docker and, for the lab, the hypervisor; nothing else. Only
# `make report` stays outside: it opens a file in the host's browser.
ifndef NIST_IN_CONTAINER
GOALS := $(or $(MAKECMDGOALS),help)
ifeq ($(GOALS),report)
report:
	@latest=$$(ls -t reports/*.html 2>/dev/null | head -1); \
	 [ -n "$$latest" ] && { echo "opening $$latest"; xdg-open "$$latest" 2>/dev/null || echo "$$latest"; } \
	 || echo "no reports yet - run make verify"
else
.PHONY: $(GOALS) _container
$(GOALS): _container ; @:
_container:
	@./nist make $(MAKECMDGOALS)
endif
else

# The inventory is the lab's, chosen here rather than by the operator: these
# targets build, apply to and assess the kickstart lab, whose hosts are in
# inventory/kickstart.yml. Hosts you bring, and the BYO lab, are in
# inventory/hosts.yml, which ./apply.sh and ./verify.sh read by default - and
# the BYO lab's env.sh sets it, so its `make pki` still finds them (DEFECTS
# 7.33). NIST_INVENTORY overrides either.
NIST_INVENTORY ?= inventory/kickstart.yml
export NIST_INVENTORY

.PHONY: help catalog catalog-present catalog-check secrets pki iso vm vm-log apply verify clean destroy teardown host-check validate test all

help:
	@echo "NIST SP 800-171r3 -> Rocky Linux 9"
	@echo
	@echo "  (the kickstart lab: its inventory is inventory/kickstart.yml)"
	@echo "  make all         catalog + secrets + iso + vm + apply + verify"
	@echo "  make catalog     extract requirements from the PDF"
	@echo "  make catalog-check  re-extract to a scratch file; fail unless byte-identical"
	@echo "  make validate    check the catalog, overlay and checks agree"
	@echo "  make test        unit tests for the assessor and the validator"
	@echo "  make secrets     generate SSH key and credentials"
	@echo "  make pki         lab CA + a certificate per inventory host (TLS forwarding)"
	@echo "  make iso         download and verify the Rocky 9 boot ISO"
	@echo "  make vm          build the hardened reference VM (unattended)"
	@echo "  make vm-log      build the log collector, so 03.03.05c can be verified"
	@echo "  make apply       apply the overlay via Ansible"
	@echo "  make verify      assess all 97 requirements on the target"
	@echo "  make report      open the newest HTML assessment report"
	@echo "  make host-check  can this host run the lab, and what to install if not"
	@echo "  make destroy     remove the kickstart VMs, and the lab network if unused"
	@echo "  make teardown    remove both labs and everything they left (asks first)"
	@echo "  make clean       remove generated reports (keeps the ISO and secrets)"

# From a bare host: check it, build the tooling, then the reference VM, harden
# it and assess it. The lab network is created on the way (vm/lab-network.sh).
all: host-check catalog-present secrets iso vm apply verify

host-check:
	./vm/host-check.sh kickstart

catalog: catalog/requirements.json

catalog/requirements.json: $(PDF) extract/extract_requirements.py
	./extract/extract_requirements.py $(PDF) -o $@

# validate reads the tracked catalog; it does not rebuild it. A fresh clone
# gives files arbitrary mtimes, so depending on the catalog target made
# validation re-extract from the PDF (and need pdftotext) on some checkouts
# and not others. catalog-check is the explicit reproducibility test.
validate:
	@[ -f catalog/requirements.json ] || { echo "no catalog - run make catalog"; exit 1; }
	@python3 tools/validate.py

# What the build targets need: the committed catalog, as it is. They used to
# depend on `catalog`, so on a fresh clone - whose file times are only the
# order of checkout - make could decide to re-extract it from the PDF with
# whatever poppler the host has (RHEL 9's 21.x was never proven to reproduce
# it). `make catalog` regenerates it only when asked.
catalog-present:
	@[ -f catalog/requirements.json ] || { echo "no catalog - run make catalog"; exit 1; }

catalog-check:
	@tmp=$$(mktemp) && trap 'rm -f "$$tmp"' EXIT && \
	 ./extract/extract_requirements.py $(PDF) -o "$$tmp" >/dev/null && \
	 cmp catalog/requirements.json "$$tmp" && \
	 echo "catalog reproduces byte for byte from $(PDF)"

test:
	@python3 -m unittest discover -s tests -v

secrets: .secrets/id_rsa

# Audit records are forwarded over TLS (03.03.05c under 03.13.08), which needs
# a CA and a certificate per host. This mints a LAB authority for the hosts in
# the inventory (NIST_INVENTORY, above); a real deployment drops its own ca.crt and HOST.crt/.key
# into NIST_PKI_DIR instead. Re-run after adding a host; existing ones are kept.
pki:
	@[ -f "$$NIST_INVENTORY" ] || { echo "no inventory at $$NIST_INVENTORY (make vm first)"; exit 1; }
	@./tools/lab-pki.sh --inventory

.secrets/id_rsa:
	@mkdir -p .secrets && chmod 700 .secrets
	@ssh-keygen -t rsa -b 3072 -N '' -C 'rl9-171-automation' -f .secrets/id_rsa >/dev/null
	@python3 -c "import secrets,string; a=string.ascii_letters+string.digits+'!@%^_-+='; \
	  open('.secrets/admin_password','w').write(''.join(secrets.choice(a) for _ in range(24))+chr(10)); \
	  open('.secrets/luks_passphrase','w').write(''.join(secrets.choice(a) for _ in range(40))+chr(10))"
	@openssl passwd -6 -stdin < .secrets/admin_password > .secrets/admin_password_hash
	@chmod 600 .secrets/*
	@echo "generated .secrets/ (keep out of version control)"

iso: $(ISO)

$(ISO):
	@mkdir -p iso
	curl -fL --retry 3 --connect-timeout 20 $(NIST_CURL_OPTS) -o $@ $(ISO_URL) \
	  || { rm -f $@; echo "the ISO download failed: tools/diagnose-lab-net.sh tests the path to the mirror"; exit 1; }
	@cd iso && curl -fsSL --connect-timeout 20 $(NIST_CURL_OPTS) -O $(ROCKY_MIRROR)/isos/x86_64/CHECKSUM \
	  && grep -A1 "Rocky-9.8-x86_64-boot.iso:" CHECKSUM | grep SHA256 \
	  | sed 's/SHA256 (\(.*\)) = \(.*\)/\2  \1/' | sha256sum -c -

vm: host-check secrets iso catalog-present
	./vm/build-vm.sh

# A single host cannot demonstrate audit-record forwarding: there is nowhere
# to forward to, so the assessor reports 03.03.05c as MANUAL rather than
# passing it. This builds the receiving end. Re-run `make apply` afterwards.
vm-log: host-check secrets iso catalog-present
	./vm/build-vm.sh --role log

# --reboot: a fresh host owes a reboot after its first apply (the new kernel,
# FIPS); this reboots it and applies again, so make all ends settled.
apply: catalog-present
	./apply.sh --reboot

verify:
	./verify.sh

# Both labs and everything they left in libvirt - guests, their volumes,
# firmware and TPM state, the lab network, base images - keeping only
# the inputs a rebuild needs (.secrets/, iso/, the BYO lab's secrets). Asks
# first. tools/lab-residue.sh lists what is there at any time.
teardown:
	./vm/lab-teardown.sh

# The kickstart VMs, then the lab network if no other guest (a BYO one) is
# still on it. `make teardown` removes every lab guest and everything else.
destroy:
	./vm/build-vm.sh --destroy
	./vm/build-vm.sh --role log --destroy
	./vm/lab-network.sh destroy-if-unused

# Reports only. It used to delete inventory/hosts.yml too, which on a host
# running the BYO lab is the live inventory; the destroy paths remove a
# guest's entry themselves.
clean:
	rm -rf reports/*.json reports/*.html
	@echo "cleaned (ISO, catalog, secrets and inventories kept)"

endif
