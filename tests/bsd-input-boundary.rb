#!/usr/bin/env ruby
# Exercise the actual receiver with native Unix datagrams and controlled parser callbacks.
require 'tmpdir'
require 'open3'

root = File.expand_path('..', __dir__)
source = File.read(File.join(root, 'syslogd.tproj/bsd_in.c'))
receiver = source[/void\s+bsd_in_acceptmsg\(int fd\)\s*\{.*?\n\}/m]
abort 'receiver not found' unless receiver
maxline = source[/^#define MAXLINE\s+\d+$/]
abort 'MAXLINE not found' unless maxline
test = <<~C
  #include <assert.h>
  #include <stdint.h>
  #include <string.h>
  #include <sys/socket.h>
  #include <sys/un.h>
  #include <unistd.h>
  #{maxline}
  #define SOURCE_BSD_SOCKET 3
  typedef struct { int unused; } asl_msg_t;
  static asl_msg_t message;
  static unsigned calls;
  static size_t expected_size;
  static char payload[MAXLINE + 17];
  static asl_msg_t *asl_input_parse(const char *line, int size, char *host, uint32_t source) {
    assert(host == NULL && source == SOURCE_BSD_SOCKET);
    assert(size == (int)expected_size);
    assert(memcmp(line, payload, expected_size) == 0);
    assert(line[size] == '\\0');
    ++calls;
    return &message;
  }
  static void process_message(asl_msg_t *parsed, uint32_t source) {
    assert(parsed == &message && source == SOURCE_BSD_SOCKET);
  }
  #{receiver}
  int main(void) {
    int fds[2];
    assert(socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, fds) == 0);
    memset(payload, 'x', sizeof payload);
    const size_t sizes[] = {1, MAXLINE - 1, MAXLINE, sizeof payload};
    for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; ++i) {
      expected_size = sizes[i] > MAXLINE ? MAXLINE : sizes[i];
      assert(send(fds[0], payload, sizes[i], 0) == (ssize_t)sizes[i]);
      bsd_in_acceptmsg(fds[1]);
      assert(calls == i + 1);
    }
    assert(send(fds[0], payload, 0, 0) == 0);
    bsd_in_acceptmsg(fds[1]);
    assert(calls == 4);
    bsd_in_acceptmsg(fds[1]); /* EAGAIN: no parser call. */
    assert(calls == 4);
    close(fds[0]); close(fds[1]);
  }
C
Dir.mktmpdir('bsd-input-boundary') do |dir|
  input = File.join(dir, 'test.c')
  binary = File.join(dir, 'test')
  File.write(input, test)
  output, status = Open3.capture2e(ENV.fetch('CC', 'clang'), '-std=c11', '-g', '-O1',
    '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
    '-fno-sanitize-recover=all', input, '-o', binary)
  abort output unless status.success?
  output, status = Open3.capture2e(binary)
  abort output unless status.success?
end
puts 'PASS: short, exact-capacity and truncated datagrams; empty/error callbacks suppressed'
