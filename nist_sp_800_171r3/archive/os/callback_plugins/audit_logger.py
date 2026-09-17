#!/usr/bin/env python3
"""
NIST 800-171 Audit Logger for Ansible (Robust Version)
Captures standard tasks AND loop items correctly.
"""

from __future__ import (absolute_import, division, print_function)
__metaclass__ = type

import json
import time
from ansible.plugins.callback import CallbackBase

class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'aggregate'
    CALLBACK_NAME = 'audit_logger'

    def __init__(self):
        super(CallbackModule, self).__init__()
        self.audit_results = []

    # --- HANDLERS FOR STANDARD TASKS ---
    def v2_runner_on_ok(self, result):
        # Ignore "Gathering Facts" and loop results (loops are handled by item_on_ok)
        if self._is_loop(result) or self._is_setup(result):
            return
        self._log_task(result, "COMPLIANT")

    def v2_runner_on_changed(self, result):
        if self._is_loop(result):
            return
        self._log_task(result, "REMEDIATED")

    def v2_runner_on_failed(self, result, ignore_errors=False):
        if self._is_loop(result):
            return
        status = "COMPLIANT (IGNORED)" if ignore_errors else "NON_COMPLIANT"
        self._log_task(result, status)

    def v2_runner_on_skipped(self, result):
        self._log_task(result, "SKIPPED")

    # --- HANDLERS FOR LOOP ITEMS ---
    def v2_runner_item_on_ok(self, result):
        self._log_task(result, "COMPLIANT")

    def v2_runner_item_on_changed(self, result):
        self._log_task(result, "REMEDIATED")

    def v2_runner_item_on_failed(self, result):
        self._log_task(result, "NON_COMPLIANT")

    def v2_runner_item_on_skipped(self, result):
        self._log_task(result, "SKIPPED")

    # --- HELPER FUNCTIONS ---
    def _is_loop(self, result):
        return 'results' in result._result

    def _is_setup(self, result):
        # Filter out 'Gathering Facts' and 'Include' tasks
        return result._task.action in ['setup', 'include_role', 'include_tasks', 'include_vars']

    def _log_task(self, result, status):
        """Extracts data and appends to the audit log."""
        task_name = result._task.get_name().strip()

        # Grab tags
        tags = result._task.tags or []

        # Grab specific loop item content if available
        item_label = ""
        if 'item' in result._result:
            # Try to make the item human-readable
            item = result._result['item']
            if isinstance(item, dict) and 'name' in item:
                item_label = f" ({item['name']})"
            elif isinstance(item, dict) and 'regexp' in item:
                item_label = f" (regex: {item['regexp']})"
            else:
                item_label = f" ({str(item)})"

        entry = {
            "control_id": task_name.split(" - ")[0],
            "task_name": task_name + item_label,
            "status": status,
            "host": result._host.get_name(),
            "timestamp": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            "tags": tags
        }
        self.audit_results.append(entry)

    def v2_playbook_on_stats(self, stats):
        """Writes the final JSON report to disk."""
        timestamp = time.strftime('%Y%m%d_%H%M%S')
        report_filename = "nist_audit_report_{}.json".format(timestamp)

        report_data = {
            "scan_meta": {
                "timestamp": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                "host_alias": "nist-hardened-arm",
                "total_checks_run": len(self.audit_results)
            },
            "summary": {
                "compliant": sum(1 for x in self.audit_results if "COMPLIANT" in x['status']),
                "remediated": sum(1 for x in self.audit_results if "REMEDIATED" in x['status']),
                "non_compliant": sum(1 for x in self.audit_results if "NON_COMPLIANT" in x['status']),
                "skipped": sum(1 for x in self.audit_results if "SKIPPED" in x['status'])
            },
            "details": self.audit_results
        }

        with open(report_filename, 'w') as f:
            json.dump(report_data, f, indent=4)

        # Print a clear summary to the console
        self._display.display("\n" + "="*60, color='cyan')
        self._display.display(f" [NIST AUDIT REPORT GENERATED] : {report_filename}", color='green')
        self._display.display(f" Total Checks: {report_data['scan_meta']['total_checks_run']}", color='white')
        self._display.display("="*60 + "\n", color='cyan')
