package MCPBridge;

use strict;
use warnings;

$SIG{PIPE} = 'IGNORE';

use JSON qw(encode_json decode_json);
use IO::Socket::INET;
use Errno qw(EAGAIN EWOULDBLOCK);

use Plugins;
use Commands;
use Log qw(message error);
use Globals;

my $PORT = 5556;
my $VERSION = '1.0';
my $PROTOCOL_VERSION = '2024-11-05';

my $listen_sock;
my %sessions;
my %pending;   # incoming POST buffering
my $next_sid = 1;
my $tools_cache;
my %pending_wait_pm;  # sid => { rpc_id, timeout_at }

Plugins::register('MCPBridge', "MCP SSE Server v$VERSION", \&on_unload);
Plugins::addHooks(
    ['mainLoop_pre' => \&on_mainLoop],
    ['packet_pubMsg' => \&on_chat_pub],
    ['packet_privMsg' => \&on_chat_priv],
    ['packet_selfChat' => \&on_chat_self],
);

start_listen();

sub on_unload {
    close($listen_sock) if $listen_sock;
}

sub start_listen {
    $listen_sock = IO::Socket::INET->new(
        LocalHost => '127.0.0.1',
        LocalPort => $PORT,
        Proto     => 'tcp',
        Listen    => 10,
        Reuse     => 1,
        Blocking  => 0,
    );
    unless ($listen_sock) {
        error "[MCPBridge] Cannot bind: $!\n";
        return;
    }
    message "[MCPBridge] MCP SSE on http://127.0.0.1:$PORT/sse\n";
}

sub on_mainLoop {
    return unless $listen_sock;

    # wait_pm timeouts
    my $now = time();
    for my $sid (keys %pending_wait_pm) {
        my $w = $pending_wait_pm{$sid};
        if ($now >= $w->{timeout_at}) {
            if ($sessions{$sid} && fileno($sessions{$sid}{sock})) {
                my $resp = encode_json({
                    jsonrpc => '2.0',
                    id => $w->{rpc_id},
                    result => {
                        content => [{
                            type => 'text',
                            text => 'wait_pm: timeout - no PM received',
                        }],
                    },
                });
                sse_send($sessions{$sid}{sock}, 'message', $resp);
            }
            message "[MCPBridge] wait_pm timeout for session $sid\n";
            delete $pending_wait_pm{$sid};
        }
    }

    # accept new connections
    while (my $client = $listen_sock->accept()) {
        $client->blocking(0);
        my $fileno = fileno($client);
        $pending{$fileno} = { sock => $client, buf => '', done => 0 };
    }

    # read data from waiting connections
    for my $fileno (keys %pending) {
        my $p = $pending{$fileno};
        next if $p->{done};

        my $chunk = '';
        my $n = $p->{sock}->sysread($chunk, 65536);
        if (defined $n && $n > 0) {
            $p->{buf} .= $chunk;
        } elsif (defined $n && $n == 0) {
            # client closed conn
        } elsif (!$!{EAGAIN} && !$!{EWOULDBLOCK}) {
            delete $pending{$fileno};
            next;
        }

        # Check if full request recieved
        my $buf = $p->{buf};
        my ($method, $uri) = $buf =~ /^(\w+)\s+(\S+)/;
        unless ($method && $uri) {
            next if length($buf) < 20;
            delete $pending{$fileno};
            next;
        }

        if ($method eq 'GET' && $uri eq '/sse') {
            $p->{done} = 1;
            open_sse($p->{sock});
            delete $pending{$fileno};
            next;
        }

        if ($method eq 'OPTIONS') {
            $p->{done} = 1;
            http_response($p->{sock}, 204, '');
            delete $pending{$fileno};
            next;
        }

        if ($method eq 'POST' && $uri =~ m{/sse\?session_id=(\d+)}) {
            my $sid = $1;
            # ищем Content-Length
            my ($cl) = $buf =~ /Content-Length:\s*(\d+)/i;
            unless ($cl) {
                if ($n && $n == 0) {
                    error "[MCPBridge] POST without Content-Length\n";
                    http_response($p->{sock}, 400, '{}');
                    delete $pending{$fileno};
                }
                next;
            }

            # lookup for body/head split
            my $hdr_end = index($buf, "\r\n\r\n");
            next if $hdr_end < 0;

            my $body_start = $hdr_end + 4;
            my $body_len = length($buf) - $body_start;

            if ($body_len < $cl) {
                # didnt read everything yet
                next unless ($n && $n == 0); # wait data or EOF
                error "[MCPBridge] Incomplete POST: $body_len < $cl\n";
                http_response($p->{sock}, 400, '{}');
                delete $pending{$fileno};
                next;
            }

            # full req
            $p->{done} = 1;
            my $body = substr($buf, $body_start, $cl);

            message "[MCPBridge] $method $uri\n";
            message "[MCPBridge] POST body ($cl bytes): $body\n";

            my $rpc = eval { decode_json($body) };
            if ($@) {
                error "[MCPBridge] JSON error: $@\n";
                http_response($p->{sock}, 400, '{"error":"bad json"}');
                delete $pending{$fileno};
                next;
            }

            my $rpc_method = $rpc->{method} // '';
            my $rpc_id = $rpc->{id};
            my $params = $rpc->{params} // {};

            message "[MCPBridge] $rpc_method id=" . ($rpc_id // 'undef') . "\n";

            if ($rpc_method =~ /^notifications\//) {
                http_response($p->{sock}, 200, '');
                delete $pending{$fileno};
                next;
            }

            my $result = dispatch($rpc_method, $params, $sid, $rpc_id);

            if (defined $rpc_id && !defined $result) {
                # async tool (wait_pm) — answer will be sent later
                http_response($p->{sock}, 200, '');
            } elsif (defined $rpc_id) {
                my $resp = encode_json({
                    jsonrpc => '2.0',
                    id => $rpc_id,
                    (ref $result eq 'HASH' && exists $result->{error}
                        ? (error => $result->{error})
                        : (result => $result))
                });

                if (exists $sessions{$sid}) {
                    sse_send($sessions{$sid}{sock}, 'message', $resp);
                }
                http_response($p->{sock}, 200, '');
            } else {
                http_response($p->{sock}, 200, '');
            }

            delete $pending{$fileno};
            next;
        }

        # unknown req
        http_response($p->{sock}, 404, '{}');
        delete $pending{$fileno};
    }
}

sub http_response {
    my ($client, $code, $body) = @_;
    my $status_text = $code == 200 ? 'OK' : ($code == 204 ? 'No Content' : 'Error');
    my $hdr = "HTTP/1.1 $code $status_text\r\n"
        . "Content-Length: " . length($body) . "\r\n"
        . "Content-Type: application/json\r\n"
        . "Access-Control-Allow-Origin: *\r\n"
        . "Connection: close\r\n\r\n";
    eval { $client->syswrite($hdr . $body); };
    $client->close();
}

sub open_sse {
    my ($client) = @_;
    my $sid = $next_sid++;

    $client->blocking(1);
    $client->autoflush(1);

    my $endpoint = "/sse?session_id=$sid";
    my $hdr = "HTTP/1.1 200 OK\r\n"
        . "Content-Type: text/event-stream\r\n"
        . "Cache-Control: no-cache\r\n"
        . "Access-Control-Allow-Origin: *\r\n"
        . "Connection: keep-alive\r\n"
        . "\r\n"
        . "event: endpoint\ndata: $endpoint\n\n";

    eval { $client->syswrite($hdr); };
    $sessions{$sid} = { sock => $client };
    message "[MCPBridge] SSE session $sid\n";
}

sub sse_send {
    my ($sock, $event, $data) = @_;
    return unless $sock && fileno($sock);
    my $payload = "event: $event\ndata: $data\n\n";
    eval { $sock->syswrite($payload); };
}

sub broadcast_event {
    my ($event_type, $data) = @_;
    my $notification = encode_json({
        jsonrpc => '2.0',
        method => 'notifications/message',
        params => {
            level => 'info',
            data => {
                type => $event_type,
                %$data,
            },
        },
    });
    message "[MCPBridge] broadcast $event_type to " . scalar(keys %sessions) . " sessions\n";
    for my $sid (keys %sessions) {
        my $sock = $sessions{$sid}{sock};
        if ($sock && fileno($sock)) {
            sse_send($sock, 'message', $notification);
            message "[MCPBridge] sent to session $sid\n";
        } else {
            message "[MCPBridge] session $sid dead, removing\n";
            delete $sessions{$sid};
        }
    }
}

sub on_chat_pub {
    my (undef, $args) = @_;
    broadcast_event('chat', {
        subtype => 'public',
        user => $args->{pubMsgUser} // '',
        msg => $args->{pubMsg} // '',
    });
}

sub on_chat_priv {
    my (undef, $args) = @_;
    my $user = $args->{privMsgUser} // '?';
    my $msg = $args->{privMsg} // '';
    message "[MCPBridge] PM from $user\n";

    # проверяем pending wait_pm
    for my $sid (keys %pending_wait_pm) {
        my $w = $pending_wait_pm{$sid};
        if ($sessions{$sid} && fileno($sessions{$sid}{sock})) {
            my $resp = encode_json({
                jsonrpc => '2.0',
                id => $w->{rpc_id},
                result => {
                    content => [{
                        type => 'text',
                        text => "PM from $user: $msg",
                    }],
                },
            });
            sse_send($sessions{$sid}{sock}, 'message', $resp);
            message "[MCPBridge] wait_pm resolved: PM from $user\n";
        }
        delete $pending_wait_pm{$sid};
    }

    broadcast_event('chat', {
        subtype => 'private',
        user => $user,
        msg => $msg,
    });
}

sub on_chat_self {
    my (undef, $args) = @_;
    broadcast_event('chat', {
        subtype => 'self',
        user => $args->{user} // '',
        msg => $args->{msg} // '',
    });
}

sub dispatch {
    my ($method, $params, $sid, $rpc_id) = @_;

    if ($method eq 'initialize') {
        return {
            protocolVersion => $PROTOCOL_VERSION,
            capabilities => { tools => {} },
            serverInfo => { name => 'openkore-mcp', version => $VERSION },
        };
    }

    return {} if $method eq 'ping';

    if ($method eq 'notifications/initialized') {
        message "[MCPBridge] Client initialized\n";
        return {};
    }

    if ($method eq 'tools/list') {
        $tools_cache //= build_tools();
        message "[MCPBridge] tools: " . scalar(@$tools_cache) . "\n";
        return { tools => $tools_cache };
    }

    if ($method eq 'tools/call') {
        my $name = $params->{name};
        my $args = $params->{arguments} // '';

        message "[MCPBridge] call: $name\n";

        if ($name eq 'wait_pm') {
            my $timeout = 86400;
            if (ref $args eq 'HASH' && exists $args->{timeout}) {
                $timeout = int($args->{timeout}) || 86400;
            } elsif ($args && $args =~ /^\d+$/) {
                $timeout = int($args);
            }
            $timeout = 86400 if $timeout < 1;

            message "[MCPBridge] wait_pm: waiting for PM (timeout=${timeout}s)\n";

            delete $pending_wait_pm{$sid};
            $pending_wait_pm{$sid} = {
                rpc_id => $rpc_id,
                timeout_at => time() + $timeout,
            };

            return undef;  # answer will be sent from on_chat_priv or by timeout
        }

        if ($name && exists $Commands::commands{$name}) {
            my $cmd = $name;
            if (ref $args eq 'HASH') {
                $cmd .= ' ' . join(' ', values %$args) if %$args;
            } elsif ($args) {
                $cmd .= ' ' . $args;
            }

            # hook cmd input
            my $output = '';
            my $hook_id = Log::addHook(sub {
                my ($type, $domain, $level, $gv, $msg) = @_;
                # filter plugin logs
                return if $msg =~ /^\[MCPBridge\]/;
                $output .= $msg;
            });

            Commands::run($cmd);

            Log::delHook($hook_id);
            $output =~ s/\s+$//;

            return { content => [{ type => 'text', text => $output || "OK: $cmd" }] };
        }

        return { error => { code => -32602, message => "Not found: $name" } };
    }

    return { error => { code => -32601, message => "Unknown method: $method" } };
}

sub build_tools {
    my @tools;
    for my $name (sort keys %Commands::commands) {
        my $cmd = $Commands::commands{$name};
        my $desc = ref($cmd->{description}) eq 'ARRAY' ? $cmd->{description}[0] : ($cmd->{description} // "cmd");
        push @tools, {
            name => $name,
            description => $desc,
            inputSchema => { type => 'object', properties => { arguments => { type => 'string' } } },
        };
    }
    push @tools, {
        name => 'wait_pm',
        description => 'Wait for incoming private message. Returns PM text when received. Default timeout: 24 hours (86400s). Optional parameter: timeout in seconds.',
        inputSchema => {
            type => 'object',
            properties => {
                timeout => {
                    type => 'number',
                    description => 'Timeout in seconds (default: 86400 = 24 hours)',
                },
            },
        },
    };
    return \@tools;
}

1;
