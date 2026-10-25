FROM docker.io/library/alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412
RUN adduser -D -u 4242 smoke \
 && install -o smoke -g smoke -m 0644 /dev/null /home/smoke/owned-by-smoke \
 && test "$(stat -c %u /home/smoke/owned-by-smoke)" = 4242
USER smoke
