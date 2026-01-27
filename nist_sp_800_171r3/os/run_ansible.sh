#!/bin/bash

ansible-playbook -i inventory.ini nist_full_remediate.yml --check --diff
ansible-playbook -i inventory.ini nist_full_remediate.yml
ansible-playbook -i inventory.ini nist_full_remediate.yml --tags network_protection
