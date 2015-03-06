use strict;
use Test::More;
use Mojo::IOLoop;
use Mojo::SMTP::Client;
use Socket 'CRLF';
use lib 't/lib';
use Utils;

my $loop = Mojo::IOLoop->singleton;
my ($pid, $sock, $host, $port) = Utils::make_smtp_server();
my $smtp = Mojo::SMTP::Client->new(address => $host, port => $port);
$smtp->send(sub {
	my $resp = shift;
	ok(!$resp->{error}, 'no error');
	is($resp->{code}, 220, 'right code');
	is($resp->{messages}[0], 'OK', 'right message');
	$loop->stop;
});

my $i;

$loop->reactor->io($sock => sub {
	my $cmd = <$sock>;
	if ($i++ == 0) {
		is($cmd, 'CONNECT'.CRLF, 'right cmd');
	}
	else {
		is($cmd, 'EHLO localhost.localdomain'.CRLF, 'right cmd');
	}
	syswrite($sock, '220 OK'.CRLF);
});
$loop->reactor->watch($sock, 1, 0);
$loop->start;
close $sock;
kill 15, $pid;

done_testing;
