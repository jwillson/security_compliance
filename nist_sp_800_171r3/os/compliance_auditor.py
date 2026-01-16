import subprocess
import json
import os

# Simplified audit map based on our STIG chunks
audit_checks = {
    "03.01.07": {
        "title": "Privileged Functions (Sudo Logging)",
        "command": "grep -q 'Defaults logfile' /etc/sudoers && echo 'PASS' || echo 'FAIL'"
    },
    "03.01.09": {
        "title": "System Use Notification (Banner)",
        "command": "[ -s /etc/issue ] && echo 'PASS' || echo 'FAIL'"
    },
    "03.03.01": {
        "title": "Event Logging (Auditd Active)",
        "command": "systemctl is-active auditd"
    },
    "03.03.06": {
        "title": "Time Stamps (Chrony Sync)",
        "command": "chronyc tracking | grep -q 'Reference ID' && echo 'PASS' || echo 'FAIL'"
    },
    "03.05.11": {
        "title": "Password Cryptography (SHA512)",
        "command": "grep -q '^ENCRYPT_METHOD SHA512' /etc/login.defs && echo 'PASS' || echo 'FAIL'"
    },
    "03.13.01": {
        "title": "Boundary Protection (Firewall)",
        "command": "systemctl is-active firewalld"
    }
}

def run_audit():
    print(f"{'ID':<10} | {'Control Title':<35} | {'Status':<10}")
    print("-" * 60)

    for cid, info in audit_checks.items():
        try:
            result = subprocess.check_output(info['command'], shell=True, stderr=subprocess.STDOUT).decode().strip()

            # Standardize active/pass vs inactive/fail
            status = "✅ COMPLIANT" if result in ["active", "PASS"] else "❌ NON-COMPLIANT"

            print(f"{cid:<10} | {info['title']:<35} | {status}")
        except subprocess.CalledProcessError:
            print(f"{cid:<10} | {info['title']:<35} | ❌ ERROR/FAIL")

if __name__ == "__main__":
    if os.geteuid() != 0:
        print("Note: Some checks may require sudo/root privileges to read system files.")
    run_audit()
