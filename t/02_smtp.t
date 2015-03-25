use strict;
use Test::More;
use Mojo::SMTP::Client;
use Socket 'CRLF';
use lib 't/lib';
use Utils;

if ($^O eq 'MSWin32') {
	plan skip_all => 'fork() support required';
}

# 1
my ($pid, $sock, $host, $port) = Utils::make_smtp_server(Mojo::IOLoop::Client::TLS);
my $smtp = Mojo::SMTP::Client->new(address => $host, port => $port, tls => Mojo::IOLoop::Client::TLS);
syswrite($sock, join(CRLF, '220 host.net', '220 hello ok', '220 from ok', '220 to ok', '220 quit ok').CRLF);

my $resp = $smtp->send(from => '', to => 'jorik@gmail.com', quit => 1);
isa_ok($resp, 'Mojo::SMTP::Client::Response');
ok(!$resp->error, 'no error') or diag $resp->error;
is($resp->code, 220, 'right response code');
is($resp->message, 'quit ok', 'right message');
is($resp->to_string, '220 quit ok'.CRLF, 'stringify message');

my @expected_cmd = (
	'CONNECT',
	'EHLO localhost.localdomain',
	'MAIL FROM:<>',
	'RCPT TO:<jorik@gmail.com>',
	'QUIT'
);

for (0..4) {
	is(scalar(<$sock>), $expected_cmd[$_].CRLF, 'right cmd was sent');
}
close $sock;
kill 15, $pid;

# 2
($pid, $sock, $host, $port) = Utils::make_smtp_server();
$smtp = Mojo::SMTP::Client->new(address => $host, port => $port, inactivity_timeout => 0.5, autodie => 1);
eval {
	$smtp->send(quit => 1);
};
ok(my $e = $@, 'timed out');
isa_ok($e, 'Mojo::SMTP::Client::Exception::Stream');
close $sock;
kill 15, $pid;

# 3
($pid, $sock, $host, $port) = Utils::make_smtp_server();
$smtp = Mojo::SMTP::Client->new(address => $host, port => $port, autodie => 1);
syswrite($sock, '500 host.net is busy'.CRLF);
eval {
	$smtp->send();
};
ok(my $e = $@, 'bad response');
isa_ok($e, 'Mojo::SMTP::Client::Exception::Response');
close $sock;
kill 15, $pid;

done_testing;
