package Utils;

use strict;
use IO::Socket 'CRLF';
use Socket;

use constant DEBUG => $ENV{MOJO_SMTP_TEST_DEBUG};

sub make_smtp_server {
	my $srv = IO::Socket::INET->new(Listen => 10)
		or die $@;
	
	socketpair(my $sock1, my $sock2, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
		or die $!;
	
	defined(my $child = fork())
		or die $!;
	
	if ($child == 0) {
		while (1) {
			my $clt = $srv->accept() or next;
			syswrite($sock2, 'CONNECT'.CRLF);
			
			while (my $resp = <$sock2>) {
				if ($resp eq '!quit'.CRLF) {
					$clt->close;
					last;
				}
				
				syswrite($clt, $resp) && DEBUG && warn "<- $resp" if $resp =~ /^\d+/;
				next if $resp =~ /^\d+-/;
				my $cmd = <$clt> or last;
				warn "-> $cmd" if DEBUG;
				syswrite($sock2, $cmd);
			}
		}
		exit;
	}
	
	return ($child, $sock1, $srv->sockhost eq '0.0.0.0' ? '127.0.0.1' : $srv->sockhost, $srv->sockport);
}

1;
