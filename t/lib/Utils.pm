package Utils;

use strict;
use IO::Socket 'CRLF';
use Socket;

sub make_smtp_server {
	my $srv = IO::Socket::INET->new(Listen => 10)
		or die $@;
	
	socketpair(my $sock1, my $sock2, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
		or die $!;
	
	defined(my $child = fork())
		or die $!;
	
	if ($child == 0) {
		my $clt = $srv->accept() or next;
		e_syswrite($sock2, 'CONNECT'.CRLF);
		
		while (my $resp = <$sock2>) {
			e_syswrite($clt, $resp) if $resp =~ /^\d+/;
			my $cmd = e_getline($clt);
			e_syswrite($sock2, $cmd);
		}
		exit;
	}
	
	return ($child, $sock1, $srv->sockhost eq '0.0.0.0' ? '127.0.0.1' : $srv->sockhost, $srv->sockport);
}

sub e_syswrite {
	my $hdl = shift;
	$hdl->syswrite(@_) or exit;
}

sub e_getline {
	my $hdl = shift;
	$hdl->getline() or exit;
}

1;
