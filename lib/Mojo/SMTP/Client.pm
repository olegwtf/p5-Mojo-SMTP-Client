package Mojo::SMTP::Client;

use Mojo::Base 'Mojo::EventEmitter';
use Mojo::IOLoop;
use Mojo::IOLoop::Delay;

use constant CRLF => "\x0d\x0a";

has address            => 'localhost';
has port               => 25;
has hello              => 'localhost.localdomain'
has connect_timeout    => sub { $ENV{MOJO_CONNECT_TIMEOUT} || 10 };
has inactivity_timeout => sub { $ENV{MOJO_INACTIVITY_TIMEOUT} // 20 };
has ioloop             => sub { Mojo::IOLoop->new };

sub send {
	my $self = shift;
	my $cb = @_ % 2 == 0 ? undef : pop;
	my %cmd = @_;
	
	my $delay = Mojo::IOLoop::Delay->new;
	my @steps;
	
	unless ($self->{stream}) {
		push @steps, sub {
			Mojo::IOLoop->client(
				address => $self->address,
				port    => $self->port,
				timeout => $self->connect_timeout,
				$delay->begin
			)
		},
		sub {
			my (undef, $err, $stream) = @_;
			die $err, "\n" if $err;
			
			$self->{stream} = $stream;
			$self->_read_response($delay->begin);
		},
		sub {
			my ($resp, $err) = @_;
		}
	}
	
	if (exists $cmd{from}) {
		push @steps, sub {
			$self->{stream}->write('MAIL FROM:<'.delete($cmd->{from}).'>'.CRLF);
			
		}
	}
}

sub _unsubscribe {
	my $self = shift;
	$self->{stream}->unsubscribe('error');
	$self->{stream}->unsubscribe('timeout');
	$self->{stream}->unsubscribe('read');
	$self->{stream}->unsubscribe('close');
}

sub _read_response {
	my ($self, $cb) = @_;
	
	$self->{stream}->timeout($self->inactivity_timeout);
	my $resp = '';
	
	$self->{stream}->on(read => sub {
		$resp .= $_[-1];
		if ($resp =~ /^\d+\s?[^\n]*\n$/m) {
			$self->_unsubscribe();
			$cb->(_parse_response($resp));
		}
	});
	$self->{stream}->on(timeout => sub {
		$self->_unsubscribe();
		$cb->(undef, 'Inactivity timeout');
	});
	$self->{stream}->on(error => sub {
		$self->_unsubscribe();
		$cb->(undef, $_[-1]);
	});
	$self->{stream}->on(close => sub {
		$self->_unsubscribe();
		delete $self->{stream};
		$cb->(undef, 'Socket closed unexpectedly by remote side');
	});
}

sub _parse_response {
	my ($code, @msg);
	
	my @lines = split CRLF, $_[0];
	($code) = $lines[0] =~ /^(\d+)/;
	
	for (@lines) {
		if (/^\d+[-\s](.+)/) {
			push @msg, $1;
		}
	}
	
	return {code => $code, messages => \@msg};
}

1;
