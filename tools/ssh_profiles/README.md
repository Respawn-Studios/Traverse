# SSH profiles and worker support

Ordinary builds use the pinned environment in `packet.py` through
`tools/worker_setup.py` and the existing network-helper builder. The current
SFTP worker source is under `tools/sftp_reader/qualification/`; its historical
directory name does not require a separate qualification build for development.
Do not replace it with a copied prototype or a system SSH subprocess.

Selected SSH configuration and certificate handling belong to
`Packages/ExplorerKit/Sources/SSHConfiguration/` and the App's existing connection
owners. The app rereads an explicitly selected certificate when connecting;
displaying a saved server grants no key, credential, shell-config or agent access.

Use `tools/dev.py` for ordinary app development and its generated native flows.
The retained packet and crash-fixture support serves explicit regression checks;
it is not permission to connect to an existing server or inspect an SSH agent.
Keep source pins and useful failure evidence when investigating a connection.
Historical private-server controllers are not contributor setup dependencies.
