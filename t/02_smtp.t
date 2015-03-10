use strict;
use Test::More;
use Mojo::SMTP::Client;
use Socket 'CRLF';
use lib 't/lib';
use Utils;

if ($^O eq 'MSWin32') {
	plan skip_all => 'fork() support required';
}

my ($pid, $sock, $host, $port) = Utils::make_smtp_server();
my $smtp = Mojo::SMTP::Client->new(address => $host, port => $port);
syswrite($sock, join(CRLF, '220 host.net', '220 hello ok', '220 from ok', '220 to ok', '220 quit ok').CRLF);

my $resp = $smtp->send(from => '', to => 'jorik@gmail.com', quit => 1);
ok(!$resp->{error}, 'no error');
is($resp->{code}, 220, 'right response code');
is(@{$resp->{messages}}, 1, 'one message in response');
is($resp->{messages}[0], 'quit ok', 'right message');

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

($pid, $sock, $host, $port) = Utils::make_smtp_server();
$smtp = Mojo::SMTP::Client->new(address => $host, port => $port, inactivity_timeout => 0.5, autodie => 1);
eval {
	$smtp->send(quit => 1);
};
ok(my $e = $@, 'timed out');
isa_ok($e, 'Mojo::SMTP::Client::Exception::Stream');
close $sock;
kill 15, $pid;

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
