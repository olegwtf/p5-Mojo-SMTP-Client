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
has hello              => 'localhost.localdomain';
has connect_timeout    => sub { $ENV{MOJO_CONNECT_TIMEOUT} || 10 };
has inactivity_timeout => sub { $ENV{MOJO_INACTIVITY_TIMEOUT} // 20 };
has ioloop             => sub { Mojo::IOLoop->new };
has autodie            => 0;

sub send {
	my $self = shift;
	my $cb = @_ % 2 == 0 ? undef : pop;
	my %cmd = @_;
	
	my @steps;
	my $expected_code;
	my $nb = $cb ? 1 : 0;
	
	my $resp_checker = sub {
		my ($delay, $resp) = @_;
		die $resp->{error} if $resp->{error};
		substr($resp->{code}, 0, 1) == $expected_code
			or Mojo::SMTP::Client::Exception::Response->throw($resp->{code}, join("\n", @{$resp->{messages}}));
		$delay->pass($resp);
	};
	
	unless ($self->{stream}) {
		push @steps, sub {
			my $delay = shift;
			# connect
			($nb ? Mojo::IOLoop->singleton : $self->ioloop)->client(
				address => $self->address,
				port    => $self->port,
				timeout => $self->connect_timeout,
				$delay->begin
			)
		},
		sub {
			# read response
			my ($delay, $err, $stream) = @_;
			Mojo::SMTP::Client::Exception::Stream->throw($err) if $err;
			
			$self->{stream} = $stream;
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
			my $delay = shift;
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
				my $delay = shift;
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
			my $delay = shift;
			$self->_cmd('DATA');
			$self->_read_response($delay->begin);
			$expected_code = CMD_MORE;
		},
		$resp_checker;
		
		if (ref $cmd{data} eq 'CODE') {
			my ($data_writer, $data_writer_cb);
			my $data_generator = delete $cmd{data};
			
			$data_writer = sub {
				my $delay = shift;
				unless ($data_writer_cb) {
					$data_writer_cb = $delay->begin;
					$self->_set_errors_handler(sub {
						$data_writer_cb->(@_);
						undef $data_writer;
					});
				}
				my $data = $data_generator->();
				
				unless (defined $data) {
					$self->_cmd(CRLF.'.');
					$self->_read_response($data_writer_cb);
					$self->_set_errors_handler(undef);
					$expected_code = CMD_OK;
					return undef $data_writer;
				}
				
				$self->{stream}->write($data, $data_writer);
			};
			
			push @steps, $data_writer, $resp_checker;
		}
		else {
			push @steps, sub {
				my $delay = shift;
				my $data_writer_cb = $delay->begin;
				$self->{stream}->write(delete $cmd{data}, $data_writer_cb);
				$self->_set_errors_handler(sub {
					$data_writer_cb->(@_);
				});
			},
			sub {
				my $delay = shift;
				if ($_[0] && $_[0]->{error}) {
					die $_[0]->{error};
				}
				
				$self->_set_errors_handler(undef);
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
			my $delay = shift;
			$self->_cmd('QUIT');
			$self->_read_response($delay->begin);
			$expected_code = CMD_OK;
		},
		$resp_checker, sub {
			my $delay = shift;
			delete($self->{stream})->close;
			$delay->pass(@_);
		};
	}
	
	if (%cmd) {
		die "unrecognized commands specified: ", join(", ", keys %cmd);
	}
	
	# non-blocking
	my $delay = Mojo::IOLoop::Delay->new->steps(@steps)->catch(sub {
		shift->emit(finish => {error => $_[0]});
	});
	$delay->on(finish => sub {
		$self->{stream}->timeout(0);
		$self->{stream}->stop;
		$cb->($_[1]);
	});
	
	# blocking
	my $resp;
	unless ($nb) {
		$cb = sub {
			$resp = shift;
			$self->ioloop->stop;
		};
		$delay->ioloop($self->ioloop);
		$delay->wait;
		return $self->autodie && $resp->{error} ? die $resp->{error} : $resp;
	}
}

sub _set_errors_handler {
	my ($self, $cb) = @_;
	
	unless ($cb) {
		return
			$self->{stream}->unsubscribe('timeout')
			               ->unsubscribe('error')
			               ->unsubscribe('close');
	}
	
	$self->{stream}->on(timeout => sub {
		delete($self->{stream})->close;
		$cb->({error => Mojo::SMTP::Client::Exception::Stream->new('Inactivity timeout')});
	});
	$self->{stream}->on(error => sub {
		delete($self->{stream})->close;
		$cb->({error => Mojo::SMTP::Client::Exception::Stream->new($_[-1])});
	});
	$self->{stream}->on(close => sub {
		delete($self->{stream});
		$cb->({error => Mojo::SMTP::Client::Exception::Stream->new('Socket closed unexpectedly by remote side')});
	});
}

sub _cmd {
	my ($self, $cmd) = @_;
	$self->{stream}->write($cmd.CRLF);
}

sub _read_response {
	my ($self, $cb) = @_;
	$self->{stream}->timeout($self->inactivity_timeout);
	$self->_set_errors_handler($cb);
	my $resp = '';
	
	$self->{stream}->on(read => sub {
		$resp .= $_[-1];
		if ($resp =~ /^\d+(?:\s[^\n]*)?\n$/m) {
			$self->{stream}->unsubscribe('read');
			$self->_set_errors_handler(undef);
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

1;
