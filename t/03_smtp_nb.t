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
	
	$smtp->send(from => 'baralgin@mail.net', to => ['jorik@40.com', 'vasya@gde.org.ru'], quit => 1, sub {
		my $resp = shift;
		ok(!$resp->{error}, 'no error');
		is($resp->{code}, 220, 'right code');
		$loop->stop;
	});
});

my $i;
my @cmd = (
	'CONNECT',
	'EHLO localhost.localdomain',
	'MAIL FROM:<baralgin@mail.net>',
	'RCPT TO:<jorik@40.com>',
	'RCPT TO:<vasya@gde.org.ru>',
	'QUIT'
);

$loop->reactor->io($sock => sub {
	my $cmd = <$sock>;
	return unless $cmd; # socket closed
	is($cmd, $cmd[$i++].CRLF, 'right cmd');
	syswrite($sock, '220 OK'.CRLF);
});
$loop->reactor->watch($sock, 1, 0);
$loop->start;
close $sock;
kill 15, $pid;


($pid, $sock, $host, $port) = Utils::make_smtp_server();
$smtp = Mojo::SMTP::Client->new(address => $host, port => $port, hello => 'dragon-host.net');
$smtp->send(
	from => 'foo@bar.net',
	to   => 'robert@mail.ru',
	data => "From: foo\@bar.net\r\nTo: robert\@mail.ru\r\nSubject: Hello!\r\n\r\nHello world",
	sub {
		my $resp = shift;
		ok(!$resp->{error}, 'no error');
		is($resp->{code}, 224, 'right code');
		is($resp->{messages}[0], 'Message sent', 'right message 1');
		is($resp->{messages}[1], 'You can send one more', 'right message 2');
		
		$smtp->send(
			from => 'jora@foo.net',
			to   => 'root@2gis.com',
			data => sub {
				read(DATA, my $buf, 64);
				return $buf;
			},
			quit => 1,
			sub {
				my $resp = shift;
				ok(!$resp->{error}, 'no error');
				$loop->stop;
			}
		)
	}
);

my $data_pos = tell(DATA);
$i = -2;
@cmd = (
	'CONNECT' => '220 CONNECT OK',
	'EHLO dragon-host.net' => '503 unknown command',
	'HELO dragon-host.net' => '221 HELO ok',
	'MAIL FROM:<foo@bar.net>' => '222 sender ok',
	'RCPT TO:<robert@mail.ru>' => '223 rcpt ok',
	'DATA' => '331 send data, please',
	'From: foo@bar.net' => '.',
	'To: robert@mail.ru' => '.',
	'Subject: Hello!' => '.',
	'' => '.',
	'Hello world' => '.',
	'.' => '224-Message sent'.CRLF.'224 You can send one more',
	'MAIL FROM:<jora@foo.net>' => '222 sender ok',
	'RCPT TO:<root@2gis.com>' => '223 rcpt ok',
	'DATA' => '331 send data, please',
	(map { s/\s+$//; $_ => '.' } <DATA>),
	'' => '.',
	'.' => '224 Message sent',
	'QUIT' => '200 See you'
);
my @cmd_const = (
	Mojo::SMTP::Client::CMD_CONNECT,
	Mojo::SMTP::Client::CMD_EHLO,
	Mojo::SMTP::Client::CMD_HELO,
	Mojo::SMTP::Client::CMD_FROM,
	Mojo::SMTP::Client::CMD_TO,
	Mojo::SMTP::Client::CMD_DATA,
	Mojo::SMTP::Client::CMD_DATA_END,
	Mojo::SMTP::Client::CMD_FROM,
	Mojo::SMTP::Client::CMD_TO,
	Mojo::SMTP::Client::CMD_DATA,
	Mojo::SMTP::Client::CMD_DATA_END,
	Mojo::SMTP::Client::CMD_QUIT,
);
my @responses = grep { /^\d+[\s-]/ } @cmd;
seek DATA, $data_pos, 0;

my $resp_cnt = 0;
$smtp->on(response => sub {
	my (undef, $cmd, $resp) = @_;
	is($cmd, $cmd_const[$resp_cnt], 'right cmd constant inside response event');
	my $resp_str;
	if ($resp->{error}) {
		my @msg = split CRLF, $resp->{error}->message;
		for my $i (0..$#msg) {
			$resp_str .= $resp->{error}->code . ($i == $#msg ? ' ' : '-') . $msg[$i];
			$resp_str .= CRLF unless $i == $#msg;
		}
	}
	else {
		for my $i (0..$#{$resp->{messages}}) {
			$resp_str .= $resp->{code} . ($i == $#{$resp->{messages}} ? ' ' : '-') . $resp->{messages}[$i];
			$resp_str .= CRLF unless $i == $#{$resp->{messages}};
		}
	}
	
	is($resp_str, $responses[$resp_cnt], 'right response');
	
	$resp_cnt++;
});
$loop->reactor->io($sock => sub {
	my $cmd = <$sock>;
	return unless $cmd; # socket closed
	$cmd =~ s/\s+$//;
	is($cmd, $cmd[$i+=2], 'right cmd');
	syswrite($sock, $cmd[$i+1].CRLF);
});
$loop->reactor->watch($sock, 1, 0);
$loop->start;
is($resp_cnt, @cmd_const, 'right response count');
close $sock;
kill 15, $pid;

done_testing;

__DATA__
Content-Transfer-Encoding: binary
Content-Type: multipart/mixed; boundary="_----------=_1425716600166160"
MIME-Version: 1.0
X-Mailer: MIME::Lite 3.028 (F2.82; B3.13; Q3.13)
Date: Sat, 7 Mar 2015 14:23:20 +0600
From: root@home.data-flow.ru
To: root@data-flow.ru
Subject: Hello world

This is a multi-part message in MIME format.

--_----------=_1425716600166160
Content-Disposition: inline
Content-Length: 12
Content-Transfer-Encoding: binary
Content-Type: text/plain

Hello sht!!!
--_----------=_1425716600166160
Content-Disposition: attachment; filename="mime-test.pl"
Content-Transfer-Encoding: base64
Content-Type: text/plain; name="mime-test.pl"

dXNlIHN0cmljdDsKI3VzZSBsaWIgJy9ob21lL29sZWcvcmVwb3MvTUlNRS1M
aXRlL2xpYic7CnVzZSBNSU1FOjpMaXRlOwoKbXkgJG1zZyA9IE1JTUU6Okxp
dGUtPm5ldygKCUZyb20gICAgPT4gJ3Jvb3RAaG9tZS5kYXRhLWZsb3cucnUn
LAoJVG8gICAgICA9PiAncm9vdEBkYXRhLWZsb3cucnUnLAoJU3ViamVjdCA9
PiAnSGVsbG8gd29ybGQnLAoJVHlwZSAgICA9PiAnbXVsdGlwYXJ0L21peGVk
JwopOwoKJG1zZy0+YXR0YWNoKFR5cGUgPT4gJ1RFWFQnLCBEYXRhID0+ICdI
ZWxsbyBzaHQhISEnKTsKJG1zZy0+YXR0YWNoKFBhdGggPT4gX19GSUxFX18s
IERpc3Bvc2l0aW9uID0+ICdhdHRhY2htZW50JywgRW5jb2RpbmcgPT4gJ2Jh
c2U2NCcpOwoKb3BlbiBteSAkZmgsICc+JywgJy90bXAvbXNnJyBvciBkaWUg
JCE7CiRtc2ctPnByaW50KCRmaCk7CmNsb3NlICRmaDsKCiNteSBAcGFydHMg
PSAkbXNnLT5wYXJ0czsKI3dhcm4gcmVmICRfIGZvciBAcGFydHM7Cg==

--_----------=_1425716600166160--
