#!/bin/bash

# 1. Verify that legacy TLS 1.0 is REJECTED
openssl s_client -connect localhost:443 -tls1

# 2. Verify that TLS 1.3 is ACCEPTED
openssl s_client -connect localhost:443 -tls1_3

# 3. Check for the presence of the HSTS security header
curl -I https://localhost
