# Box auth-boundary research

Target: public Box guest-agent and node-manager artifacts.

Goal: validate novel authorization failures only, with local harnesses before any production confirmation.

Primary candidate classes:
- guest-agent shared-key authentication bypass leading to shell/file/process access
- node-manager HMAC canonicalization bypass leading to VM lifecycle or secret rotation access
- machine-token capability confusion crossing per-Box boundaries

Current negative controls:
- bridge peer-isolation prerequisite repro remained blocked
- reconcile DNAT tenant-hairpin bypass hypothesis was falsified
