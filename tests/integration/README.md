Integration test instructions

Run locally with Docker Compose:

1. Build and run the test service (it uses the official Ubuntu image):
   docker compose up --build --abort-on-container-exit --exit-code-from tester

2. The test runs inside the container and will print PASS/FAIL messages.

Notes:

- Tests create temporary files under /tmp inside the container and clean up after themselves.
- If you need to debug interactively, run the container with a shell and inspect /workspace and /root/.config/opencode.
