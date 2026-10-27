FROM docker.io/moby/buildkit:v0.34.0-rootless@sha256:65eca3c01cd1180c8f64565c4e3c5983af5145818b0e6fa863385d099eb73855
RUN nc -z -w 5 127.0.0.1 1234
RUN if buildctl --addr tcp://127.0.0.1:1234 debug workers; then echo "a build step drove buildkitd" >&2; exit 1; fi
RUN for root in /proc/[0-9]*/root; do if head -c 1 "$root/run/buildkit/server/key.pem" >/dev/null 2>&1; then echo "a build step read the server key through $root" >&2; exit 1; fi; done
