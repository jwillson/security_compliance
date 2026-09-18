# NIST SP 800-171r3 overlay for Rocky Linux 9

SHELL := /bin/bash
PDF    := NIST.SP.800-171r3.pdf
ISO_URL := https://dl.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9.8-x86_64-boot.iso
ISO     := iso/Rocky-9.8-x86_64-boot.iso

.PHONY: help catalog secrets pki iso vm vm-log apply verify report clean destroy validate all

help:
	@echo "NIST SP 800-171r3 -> Rocky Linux 9"
	@echo
	@echo "  make all         catalog + secrets + iso + vm + apply + verify"
	@echo "  make catalog     extract requirements from the PDF"
	@echo "  make validate    check the catalog, overlay and checks agree"
	@echo "  make secrets     generate SSH key and credentials"
	@echo "  make pki         lab CA + a certificate per inventory host (TLS forwarding)"
	@echo "  make iso         download and verify the Rocky 9 boot ISO"
	@echo "  make vm          build the hardened reference VM (unattended)"
	@echo "  make vm-log      build the log collector, so 03.03.05c can be verified"
	@echo "  make apply       apply the overlay via Ansible"
	@echo "  make verify      assess all 97 requirements on the target"
	@echo "  make report      open the newest HTML assessment report"
	@echo "  make destroy     remove the VM and its disk"
	@echo "  make clean       remove generated artifacts (keeps the ISO)"

all: catalog secrets iso vm apply verify

catalog: catalog/requirements.json

catalog/requirements.json: $(PDF) extract/extract_requirements.py
	./extract/extract_requirements.py $(PDF) -o $@

validate: catalog/requirements.json
	@python3 tools/validate.py

secrets: .secrets/id_rsa

# Audit records are forwarded over TLS (03.03.05c under 03.13.08), which needs
# a CA and a certificate per host. This mints a LAB authority for the hosts in
# inventory/hosts.yml; a real deployment drops its own ca.crt and HOST.crt/.key
# into NIST_PKI_DIR instead. Re-run after adding a host; existing ones are kept.
pki:
	@[ -f inventory/hosts.yml ] || { echo "no inventory/hosts.yml"; exit 1; }
	@./tools/lab-pki.sh $$(ansible-inventory --list 2>/dev/null | python3 -c \
	  'import json,sys; d=json.load(sys.stdin); hv=d["_meta"]["hostvars"]; \
	   print(" ".join(f"{h}={hv[h][\"ansible_host\"]}" for h in d["cui_hosts"]["hosts"]))')

.secrets/id_rsa:
	@mkdir -p .secrets && chmod 700 .secrets
	@ssh-keygen -t rsa -b 3072 -N '' -C 'rl9-171-automation' -f .secrets/id_rsa >/dev/null
	@python3 -c "import secrets,string; a=string.ascii_letters+string.digits+'!@%^_-+='; \
	  open('.secrets/admin_password','w').write(''.join(secrets.choice(a) for _ in range(24))+chr(10)); \
	  open('.secrets/luks_passphrase','w').write(''.join(secrets.choice(a) for _ in range(40))+chr(10))"
	@openssl passwd -6 "$$(cat .secrets/admin_password)" > .secrets/admin_password_hash
	@printf '%s\n' '#!/usr/bin/env bash' \
	  '# Supplies the knowledge factor for hosts enforcing 03.05.03 MFA' \
	  '# (sshd AuthenticationMethods publickey,password).' \
	  'exec cat "$$(dirname "$$(readlink -f "$$0")")/admin_password"' \
	  > .secrets/askpass.sh
	@chmod 600 .secrets/* && chmod 700 .secrets/askpass.sh
	@echo "generated .secrets/ (keep out of version control)"

iso: $(ISO)

$(ISO):
	@mkdir -p iso
	curl -L --retry 3 -o $@ $(ISO_URL)
	@cd iso && curl -sL -O https://dl.rockylinux.org/pub/rocky/9/isos/x86_64/CHECKSUM \
	  && grep -A1 "Rocky-9.8-x86_64-boot.iso:" CHECKSUM | grep SHA256 \
	  | sed 's/SHA256 (\(.*\)) = \(.*\)/\2  \1/' | sha256sum -c -

vm: secrets iso catalog
	./vm/build-vm.sh

# A single host cannot demonstrate audit-record forwarding: there is nowhere
# to forward to, so the assessor reports 03.03.05c as MANUAL rather than
# passing it. This builds the receiving end. Re-run `make apply` afterwards.
vm-log: secrets iso catalog
	./vm/build-vm.sh --role log

apply: catalog
	./apply.sh

verify:
	./verify.sh

report:
	@latest=$$(ls -t reports/*.html 2>/dev/null | head -1); \
	 [ -n "$$latest" ] && { echo "opening $$latest"; xdg-open "$$latest" 2>/dev/null || echo "$$latest"; } \
	 || echo "no reports yet - run make verify"

destroy:
	./vm/build-vm.sh --destroy
	./vm/build-vm.sh --role log --destroy

clean:
	rm -rf reports/*.json reports/*.html inventory/hosts.yml
	@echo "cleaned (ISO, catalog and secrets kept)"
