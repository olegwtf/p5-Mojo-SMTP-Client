package Mojo::SMTP::Client;

use Mojo::Base 'Mojo::EventEmitter';
use Mojo::IOLoop;
use Mojo::IOLoop::Delay;
use Mojo::SMTP::Client::Exception;

our $VERSION = 0.01;

use constant {
	CMD_OK     => 2,
	CMD_MORE   => 3,
	CMD_REJECT => 4,
	CMD_ERROR  => 5,
	CRLF       => "\x0d\x0a",
};

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
	my $expected_code;
	
	my $resp_checker = sub {
		my ($resp, $err) = @_;
		die $err, "\n" if $err;
		_check_response($resp, $expected_code);
		$delay->pass($resp);
	};
	
	my $stream_error;
	
	unless ($self->{stream}) {
		push @steps, sub {
			# connect
			Mojo::IOLoop->client(
				address => $self->address,
				port    => $self->port,
				timeout => $self->connect_timeout,
				$delay->begin
			)
		},
		sub {
			# read response
			my (undef, $err, $stream) = @_;
			Mojo::IOLoop::Stream->throw($err) if $err;
			
			$self->{stream} = $stream;
			$stream->on(timeout => sub {
				delete($self->{stream})->close;
				$stream_error = Mojo::SMTP::Client::Exception::Stream->new('Inactivity timeout');
			});
			$stream->on(error => sub {
				delete($self->{stream})->close;
				$stream_error = Mojo::SMTP::Client::Exception::Stream->new($_[-1]);
			});
			$stream->on(close => sub {
				delete($self->{stream})->close;
				$stream_error = Mojo::SMTP::Client::Exception::Stream->new('Socket closed unexpectedly by remote side');
			});
			
			$self->_read_response($delay->begin);
			$expected_code = CMD_OK;
		},
		# check response
		$resp_checker
	}
	else {
		$self->{stream}->start;
	}
	
	if (exists $cmd{from}) {
		# FROM
		push @steps, sub {
			$self->_cmd('MAIL FROM:<'.delete($cmd{from}).'>');
			$self->_read_response($delay->begin);
			$expected_code = CMD_OK;
		},
		$resp_checker
	}
	if (exists $cmd{to}) {
		# TO
		for my $to (ref $cmd{to} ? @{$cmd{to}} : $cmd{to}) {
			push @steps, sub {
				$self->_cmd('RCPT TO:<'.$to.'>');
				$self->_read_response($delay->begin);
				$expected_code = CMD_OK;
			},
			$resp_checker
		}
		delete $cmd{to};
	}
	if (exists $cmd{data}) {
		# DATA
		push @steps, sub {
			$self->_cmd('DATA');
			$self->_read_response($delay->begin);
			$expected_code = CMD_MORE;
		},
		$resp_checker;
		
		if (ref $cmd{data} eq 'CODE') {
			my $data_writer; $data_writer = sub {
				my $data = $cmd{data}->();
				unless (defined $data) {
					undef $data_writer;
					$self->_cmd(CRLF.'.');
					$self->_read_response($delay->begin);
					$expected_code = CMD_OK;
					return;
				}
				
				$self->{stream}->write($data, $data_writer);
			};
			
			push @steps, $data_writer, $resp_checker;
			delete $cmd{data};
		}
		else {
			push @steps, sub {
				$self->{stream}->write(delete $cmd{data}, $delay->begin);
			},
			sub {
				$self->_cmd(CRLF.'.');
				$self->_read_response($delay->begin);
				$expected_code = CMD_OK;
			},
			$resp_checker
		}
	}
	if (exists $cmd{quit}) {
		# QUIT
		delete $cmd{quit};
		push @steps, sub {
			$self->_cmd('QUIT');
			$self->_read_response($delay->begin);
			$expected_code = CMD_OK;
		},
		$resp_checker, sub {
			delete $self->{stream};
			$delay->pass(@_);
		};
	}
	
	if (%cmd) {
		die "unrecognized commands specified: ", join(", ", keys %cmd);
	}
	
	my $nb = $cb ? 1 : 0;
	my ($resp, $err);
	
	unless ($nb) {
		$cb = sub {
			($resp, $err) = @_;
			$self->ioloop->stop;
		}
	}
	
	# non-blocking
	$delay->steps(@steps)->catch(sub {
		$cb->(undef, pop);
	});
	
	# blocking
	unless ($nb) {
		$delay->ioloop($self->ioloop);
		$delay->wait;
		return ($resp, $err);
	}
}

sub _cmd {
	my ($self, $cmd) = @_;
	die $self->{stream_error} if $self->{stream_error};
	
	$self->{stream}->write($cmd.CRLF);
}

sub _read_response {
	my ($self, $cb) = @_;
	die $self->{stream_error} if $self->{stream_error};
	
	$self->{stream}->timeout($self->inactivity_timeout);
	my $resp = '';
	
	$self->{stream}->on(read => sub {
		$resp .= $_[-1];
		if ($resp =~ /^\d+\s?[^\n]*\n$/m) {
			$self->{stream}->unsubscribe('read');
			$cb->(_parse_response($resp));
		}
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

sub _check_response {
	my ($resp, $expected_code) = @_;
	
	substr($resp->{code}, 0, 1) == $expected_code
		or Mojo::SMTP::Client::Exception::Response->throw($resp->{code}, join("\n", $resp->{messages}));
}

1;
