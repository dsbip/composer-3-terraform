"""Minimal stand-in for the two read-only Google APIs that
data.google_project calls during `terraform plan` (Resource Manager GetProject
and Cloud Billing GetBillingInfo), so real Terraform can plan offline."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parts = self.path.split("?")[0].strip("/").split("/")
        if parts[-1] == "billingInfo":
            pid = parts[-2]
            return self._json(200, {"name": f"projects/{pid}/billingInfo", "projectId": pid,
                                    "billingAccountName": "", "billingEnabled": False})
        if len(parts) >= 2 and parts[-2] == "projects":
            pid = parts[-1]
            return self._json(200, {"projectNumber": "123456789012", "projectId": pid,
                                    "lifecycleState": "ACTIVE", "name": pid})
        return self._json(404, {"error": {"code": 404, "message": "not found", "status": "NOT_FOUND"}})

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
