#!/bin/bash

echo "Starting NIST SP 800-171r3 Technical Remediation..."

# 1. Access Control: System Use Notification (03.01.09)
echo "[*] Configuring Login Banners..."
echo "Authorized uses only. All activity may be monitored and recorded." > /etc/issue
cp /etc/issue /etc/issue.net
sed -i 's/^#Banner.*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
systemctl reload sshd

# 2. Access Control: Session Timeout (03.01.10)
echo "[*] Setting Shell Inactivity Timeout (900s)..."
cat <<EOF > /etc/profile.d/nist_tmout.sh
TMOUT=900
readonly TMOUT
export TMOUT
EOF
chmod +x /etc/profile.d/nist_tmout.sh

# 3. Audit & Accountability: Enable Auditd (03.03.01)
echo "[*] Ensuring Auditd is installed and active..."
yum install -y audit
systemctl enable --now auditd
# Add a basic rule to watch the password file
echo "-w /etc/shadow -p wa -k identity_integrity" >> /etc/audit/rules.d/audit.rules
augenrules --load

# 4. Identification & Auth: Password Hashing (03.05.11)
echo "[*] Enforcing SHA512 Password Hashing..."
sed -i 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' /etc/login.defs

# 5. System Communications: SSH Hardening (03.13.08)
echo "[*] Hardening SSH Ciphers..."
# Disable legacy root login and restrict ciphers
sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
echo "Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com" >> /etc/ssh/sshd_config
systemctl reload sshd

# 6. System Integrity: File Integrity Monitoring (03.14.07)
echo "[*] Installing AIDE (File Integrity Monitoring)..."
yum install -y aide
if [ ! -f /var/lib/aide/aide.db.gz ]; then
    echo "[!] Initializing AIDE database (this may take a moment)..."
    aide --init
    mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
fi

echo "-------------------------------------------------------"
echo "Remediation Complete. Please run your Audit Script again."
