package Mojo::SMTP::Client;

use Mojo::Base 'Mojo::EventEmitter';
use Mojo::IOLoop;
use Mojo::IOLoop::Delay;
use Mojo::SMTP::Client::Exception;
use Carp;

our $VERSION = 0.03;

use constant {
	CMD_OK       => 2,
	CMD_MORE     => 3,
	
	CMD_CONNECT  => 1,
	CMD_EHLO     => 2,
	CMD_HELO     => 3,
	CMD_FROM     => 4,
	CMD_TO       => 5,
	CMD_DATA     => 6,
	CMD_DATA_END => 7,
	CMD_RESET    => 8,
	CMD_QUIT     => 9,
	
	CRLF         => "\x0d\x0a",
};

our %CMD = (
	&CMD_CONNECT  => 'CMD_CONNECT',
	&CMD_EHLO     => 'CMD_EHLO',
	&CMD_HELO     => 'CMD_HELO',
	&CMD_FROM     => 'CMD_FROM',
	&CMD_TO       => 'CMD_TO',
	&CMD_DATA     => 'CMD_DATA',
	&CMD_DATA_END => 'CMD_DATA_END',
	&CMD_RESET    => 'CMD_RESET',
	&CMD_QUIT     => 'CMD_QUIT',
);

has address            => 'localhost';
has port               => 25;
has hello              => 'localhost.localdomain';
has connect_timeout    => sub { $ENV{MOJO_CONNECT_TIMEOUT} || 10 };
has inactivity_timeout => sub { $ENV{MOJO_INACTIVITY_TIMEOUT} // 20 };
has ioloop             => sub { Mojo::IOLoop->new };
has autodie            => 0;

my %cmd = (
	from  => 1,
	to    => 1,
	data  => 1,
	reset => 1,
	quit  => 1,
);

sub send {
	my $self = shift;
	my $cb = @_ % 2 == 0 ? undef : pop;
	my @cmd = @_;
	
	my @steps;
	my $expected_code;
	my $nb = $cb ? 1 : 0;
	
	my $resp_checker = sub {
		my ($delay, $resp) = @_;
		$self->emit(response => $self->{last_cmd}, $resp);
		
		die $resp->{error} if $resp->{error};
		substr($resp->{code}, 0, 1) == $expected_code
			or Mojo::SMTP::Client::Exception::Response->throw($resp->{code}, $resp->{code}.' '.join("\n", @{$resp->{messages}}));
		$delay->pass($resp);
	};
	
	if ($self->{stream} && (($self->{server} ne $self->_server) || $self->{stream}->is_readable)) {
		# user changed SMTP server or server sent smth while it shouldn't
		delete($self->{stream})->close;
	}
	
	unless ($self->{stream}) {
		push @steps, sub {
			my $delay = shift;
			# connect
			$self->emit('start');
			$self->{server} = $self->_server;
			$self->{last_cmd} = CMD_CONNECT;
			$self->_ioloop($nb)->client(
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
		$resp_checker,
		# HELO
		sub {
			my $delay = shift;
			$self->_cmd('EHLO ' . $self->hello, CMD_EHLO);
			$self->_read_response($delay->begin);
			$expected_code = CMD_OK;
		}, 
		sub {
			eval { $resp_checker->(@_); $_[1]->{checked} = 1 };
			if (my $err = $@) {
				die $err unless $err->isa('Mojo::SMTP::Client::Exception::Response');
				my $delay = shift;
				$self->_cmd('HELO ' . $self->hello, CMD_HELO);
				$self->_read_response($delay->begin);
			}
		},
		sub {
			my ($delay, $resp) = @_;
			return $delay->pass($resp) if delete $resp->{checked};
			$resp_checker->($delay, $resp);
		};
	}
	else {
		$self->{stream}->start;
	}
	
	for (my $i=0; $i<@cmd; $i+=2) {
		my $mi = $i+1;
		
		if ($cmd[$i] eq 'from') { # FROM
			push @steps, sub {
				my $delay = shift;
				$self->_cmd('MAIL FROM:<'.$cmd[$mi].'>', CMD_FROM);
				$self->_read_response($delay->begin);
				$expected_code = CMD_OK;
			},
			$resp_checker
		}
		elsif ($cmd[$i] eq 'to') { # TO
			for my $to (ref $cmd[$mi] ? @{$cmd[$mi]} : $cmd[$mi]) {
				push @steps, sub {
					my $delay = shift;
					$self->_cmd('RCPT TO:<'.$to.'>', CMD_TO);
					$self->_read_response($delay->begin);
					$expected_code = CMD_OK;
				},
				$resp_checker
			}
		}
		elsif ($cmd[$i] eq 'data') { # DATA
			# DATA
			push @steps, sub {
				my $delay = shift;
				$self->_cmd('DATA', CMD_DATA);
				$self->_read_response($delay->begin);
				$expected_code = CMD_MORE;
			},
			$resp_checker;
			
			if (ref $cmd[$mi] eq 'CODE') {
				my ($data_writer, $data_writer_cb);
				my $was_nl;
				
				$data_writer = sub {
					my $delay = shift;
					unless ($data_writer_cb) {
						$data_writer_cb = $delay->begin;
						$self->_set_errors_handler(sub {
							$data_writer_cb->($delay, @_);
							undef $data_writer;
						});
					}
					
					my $data = $cmd[$mi]->();
					
					unless (length(ref $data ? $$data : $data) > 0) {
						$self->_cmd(($was_nl ? '' : CRLF).'.', CMD_DATA_END);
						$self->_read_response($data_writer_cb);
						$self->_set_errors_handler(undef);
						$expected_code = CMD_OK;
						return undef $data_writer;
					}
					
					$was_nl = _has_nl($data);
					$self->{stream}->write(ref $data ? $$data : $data, $data_writer);
				};
				
				push @steps, $data_writer, $resp_checker;
			}
			else {
				push @steps, sub {
					my $delay = shift;
					my $data_writer_cb = $delay->begin;
					$self->{stream}->write(ref $cmd[$mi] ? ${$cmd[$mi]} : $cmd[$mi], $data_writer_cb);
					$self->_set_errors_handler(sub {
						$data_writer_cb->(@_);
					});
				},
				sub {
					my ($delay, $resp) = @_;
					if ($resp && $resp->{error}) {
						die $resp->{error};
					}
					
					$self->_set_errors_handler(undef);
					$self->_cmd((_has_nl($cmd[$mi]) ? '' : CRLF).'.', CMD_DATA_END);
					$self->_read_response($delay->begin);
					$expected_code = CMD_OK;
				},
				$resp_checker
			}
		}
		elsif ($cmd[$i] eq 'reset') { # RESET
			push @steps, sub {
				my $delay = shift;
				$self->_cmd('RSET', CMD_RESET);
				$self->_read_response($delay->begin);
				$expected_code = CMD_OK;
			},
			$resp_checker
		}
		elsif ($cmd[$i] eq 'quit') { # QUIT
			push @steps, sub {
				my $delay = shift;
				$self->_cmd('QUIT', CMD_QUIT);
				$self->_read_response($delay->begin);
				$expected_code = CMD_OK;
			},
			$resp_checker, sub {
				my $delay = shift;
				delete($self->{stream})->close;
				$delay->pass(@_);
			}
		}
		else {
			croak 'unrecognized command: ', $cmd[$i];
		}
	}
	
	# non-blocking
	my $delay = Mojo::IOLoop::Delay->new(ioloop => $self->_ioloop($nb))->steps(@steps)->catch(sub {
		shift->emit(finish => {error => $_[0]});
	});
	$delay->on(finish => sub {
		if ($self->{stream}) {
			$self->{stream}->timeout(0);
			$self->{stream}->stop;
		}
		$cb->($self, $_[1]);
	});
	
	# blocking
	my $resp;
	unless ($nb) {
		$cb = sub {
			$resp = pop;
		};
		$delay->wait;
		return $self->autodie && $resp->{error} ? die $resp->{error} : $resp;
	}
}

sub _ioloop {
	my ($self, $nb) = @_;
	return $nb ? Mojo::IOLoop->singleton : $self->ioloop;
}

sub _server {
	my $self = shift;
	return $self->address.':'.$self->port;
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
		delete($self->{stream});
		$cb->($self, {error => Mojo::SMTP::Client::Exception::Stream->new('Inactivity timeout')});
	});
	$self->{stream}->on(error => sub {
		delete($self->{stream});
		$cb->($self, {error => Mojo::SMTP::Client::Exception::Stream->new($_[-1])});
	});
	$self->{stream}->on(close => sub {
		delete($self->{stream});
		$cb->($self, {error => Mojo::SMTP::Client::Exception::Stream->new('Socket closed unexpectedly by remote side')});
	});
}

sub _cmd {
	my ($self, $cmd, $cmd_const) = @_;
	$self->{last_cmd} = $cmd_const;
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
			$cb->($self, _parse_response($resp));
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

sub _has_nl {
	if (ref $_[0]) {
		return ${$_[0]} =~ /\012$/;
	}
	$_[0] =~ /\012$/;
}

1;

__END__

=pod

=encoding utf8

=head1 NAME

Mojo::SMTP::Client - non-blocking SMTP client based on Mojo::IOLoop

=head1 SYNOPSIS

=over

	# blocking
	my $smtp = Mojo::SMTP::Client->new(address => '10.54.17.28', autodie => 1);
	$smtp->send(
		from => 'me@from.org',
		to => 'you@to.org',
		data => join("\r\n", 'From: me@from.org',
		                     'To: you@to.org',
		                     'Subject: Hello world!',
		                     '',
		                     'This is my first message!'
		        ),
		quit => 1
	);
	warn "Sent successfully"; # else will throw exception because of `autodie'

=back

=over

	# non-blocking
	my $smtp = Mojo::SMTP::Client->new(address => '10.54.17.28');
	$smtp->send(
		from => 'me@from.org',
		to => 'you@to.org',
		data => join("\r\n", 'From: me@from.org',
		                     'To: you@to.org',
		                     'Subject: Hello world!',
		                     '',
		                     'This is my first message!'
	            ),
		quit => 1,
		sub {
			my ($smtp, $resp) = @_;
			warn $resp->{error} ? 'Failed to send: '.$resp->{error} : 'Sent successfully';
			Mojo::IOLoop->stop;
		}
	);
	
	Mojo::IOLoop->start;

=back

=head1 DESCRIPTION

With C<Mojo::SMTP::Client> you can easily send emails from your Mojolicious application without
blocking of C<Mojo::IOLoop>.

=head1 EVENTS

C<Mojo::SMTP::Client> inherits all events from L<Mojo::EventEmitter> and can emit the following new ones

=head2 start

	$smtp->on(start => sub {
		my ($smtp) = @_;
		# some servers delays first response to prevent SPAM
		$smtp->inactivity_timeout(5*60);
	});

Emitted whenever a new connection is about to start.

=head2 response

	$smtp->on(response => sub {
		my ($smtp, $cmd, $resp) = @_;
		if ($cmd == Mojo::SMTP::Client::CMD_CONNECT) {
			# and after first response others should be fast enough
			$smtp->inactivity_timeout(10);
		}
	});

Emitted for each SMTP response from the server. C<$cmd> is a command L<constant|/CONSTANTS> for which this
response was sent. For C<$resp> description see L</send>.

=head1 ATTRIBUTES

C<Mojo::SMTP::Client> implements the following attributes, which you can set in the constructor or get/set later
with object method call

=head2 address

Address of SMTP server (ip or domain name). Default is C<localhost>

=head2 port

Port of SMTP server. Default is C<25>

=head2 hello

SMTP requires that you identify yourself. This option specifies a string to pass as your mail domain.
Default is C<localhost.localdomain>

=head2 connect_timeout

Maximum amount of time in seconds establishing a connection may take before getting canceled,
defaults to the value of the C<MOJO_CONNECT_TIMEOUT> environment variable or C<10>

=head2 inactivity_timeout

Maximum amount of time in seconds a connection can be inactive before getting closed,
defaults to the value of the C<MOJO_INACTIVITY_TIMEOUT> environment variable or C<20>.
Setting the value to C<0> will allow connections to be inactive indefinitely

=head2 ioloop

Event loop object to use for blocking I/O operations, defaults to a L<Mojo::IOLoop> object

=head2 autodie

Defines should or not C<Mojo::SMTP::Client> throw exceptions for any type of errors. This only usable for
blocking usage of C<Mojo::SMTP::Client>, because non-blocking one should never die. Throwed
exception will be one of the specified in L<Mojo::SMTP::Client::Exception>. When autodie attribute
has false value you should check C<$respE<gt>{error}> yourself. Default is false.

=head1 METHODS

C<Mojo::SMTP::Client> inherits all methods from L<Mojo::EventEmitter> and implements the following new ones

=head2 send

	$smtp->send(
		from => $mail_from,
		to   => $rcpt_to,
		data => $data,
		quit => 1,
		$nonblocking ? $cb : ()
	);

Send specified commands to SMTP server. Arguments should be C<key =E<gt> value> pairs where C<key> is a command 
and C<value> is a value for this command. C<send> understands the following commands:

=over

=item from

From which email this message was sent. Value for this cammand should be a string with email

	$smtp->send(from => 'root@cpan.org');

=item to

To which email(s) this message should be sent. Value for this cammand should be a string with email
or reference to array with email strings (for more than one recipient)

	$smtp->send(to => 'oleg@cpan.org');
	$smtp->send(to => ['oleg@cpan.org', 'do_not_reply@cpantesters.org']);

=item reset

After this command server should forget about any started mail transaction and reset it status as it was after response to C<EHLO>/C<HELO>.
Note: transaction considered started after C<MAIL FROM> (C<from>) command.

	$smtp->send(reset => 1);

=item data

Email body to be sent. Value for this command should be a string (or reference to a string) with email body or reference to subroutine
each call of which should return some chunk of the email as string (or reference to a string) and empty string (or reference to empty string)
at the end (useful to send big emails in memory-efficient way)

	$smtp->send(data => "Subject: This is my first message\r\n\r\nSent from Mojolicious app");
	$smtp->send(data => sub { sysread(DATA, my $buf, 1024); $buf });

=item quit

Send C<QUIT> command to SMTP server which will close the connection. So for the next use of this server connection will be
reestablished. If you want to send several emails with this server it will be more efficient to not quit
the connection until last email will be sent.

=back

For non-blocking usage last argument to C<send> should be reference to subroutine which will be called when result will
be available. Subroutine arguments will be C<($smtp, $resp)>. Where C<$resp> is reference to a hash with
response. This hash may has this keys: C<error>, C<code>, C<messages>. First you should check C<error> - 
if it has true value this means that it was error somewhere while sending. C<$resp-E<gt>{error}> will be one
of C<Mojo::SMTP::Client::Exception::*> objects defined in L<Mojo::SMTP::Client::Exception>. If C<error> has
false value you can get code and messages for last command with C<$resp-E<gt>{code}> (number) and
C<$resp-E<gt>{messages}> (reference to array with strings).

For blocking usage C<$resp> will be returned as result of C<$smtp-E<gt>send> call. C<$resp> is the same as for
non-blocking result. If L</autodie> attribute has true value C<send> will throw an exception on any error.
Which will be one of C<Mojo::SMTP::Client::Exception::*>.

B<Note>. For SMTP protocol it is important to send commands in certain order. Also C<send> will send all commands in order you are
specified. So, it is important to pass arguments to C<send> in right order. For basic usage this will always be:
C<from -E<gt> to -E<gt> data -E<gt> quit>. You should also know that it is absolutely correct to specify several non-unique commands.
For example you can send several emails with one C<send> call:

	$smtp->send(
		from => 'someone@somewhere.com',
		to   => 'somebody@somewhere.net',
		data => $mail_1,
		from => 'frodo@somewhere.com',
		to   => 'garry@somewhere.net',
		data => $mail_2,
		quit => 1
	);

B<Note>. Connection to SMTP server will be made on first C<send> or for each C<send> when socket connection not already estabilished
(was closed by C<QUIT> command or errors in the stream). It is error to make several simultaneous non-blocking C<send> calls on the
same C<Mojo::SMTP::Client>, because each client has one global stream per client. So, you need to create several
clients to make simultaneous sending.

=head1 CONSTANTS

C<Mojo::SMTP::Client> has this non-importable constants

	CMD_CONNECT  # client connected to SMTP server
	CMD_EHLO     # client sent EHLO command
	CMD_HELO     # client sent HELO command
	CMD_FROM     # client sent MAIL FROM command
	CMD_TO       # client sent RCPT TO command
	CMD_DATA     # client sent DATA command
	CMD_DATA_END # client sent . command
	CMD_RESET    # client sent RSET command
	CMD_QUIT     # client sent QUIT command

=head1 VARIABLES

C<Mojo::SMTP::Client> has this non-importable variables

=over

=item %CMD

Get human readable command by it constant

	print $Mojo::SMTP::Client::CMD{ Mojo::SMTP::Client::CMD_EHLO };

=back

=head1 COOKBOOK

=head2 How to send simple ASCII message

ASCII message is simple enough, so you can generate it by hand

	$smtp->send(
		from => 'me@home.org',
		to   => 'you@work.org',
		data => join(
			"\r\n",
			'MIME-Version: 1.0',
			'Subject: Subject of the message',
			'From: me@home.org',
			'To: you@work.org',
			'Content-Type: text/plain; charset=UTF-8',
			'',
			'Text of the message'
		)
	);

However it is not recommended to generate emails by hand if you are not
familar with MIME standard. For more convenient approaches see below.

=head2 How to send text message with possible non-ASCII characters

For more convinient way to generate emails we can use some email generators
available on CPAN. L<MIME::Lite> for example. With such modules we can get
email as a string and send it with C<Mojo::SMTP::Client>

	use MIME::Lite;
	use Encode;
	
	my $msg = MIME::Lite->new(
		Type    => 'text',
		From    => 'me@home.org',
		To      => 'you@work.org',
		Subject => Encode::encode('MIME-Header', '世界, 労働, 5月!'),
		Data    => 'Novosibirsk (Russian: Новосибирск; IPA: [nəvəsʲɪˈbʲirsk]) is the third most populous '.
		           'city in Russia after Moscow and St. Petersburg and the most populous city in Asian Russia'
	);
	$msg->attr('content-type.charset' => 'UTF-8');
	
	$smtp->send(
		from => 'me@home.org',
		to   => 'you@work.org',
		data => $msg->as_string
	);

=head2 How to send message with attachment

This is also simple with help of L<MIME::Lite>

	use MIME::Lite;
	
	my $msg = MIME::Lite->new(
		Type    => 'multipart/mixed',
		From    => 'me@home.org',
		To      => 'you@work.org',
		Subject => 'statistic for 10.03.2015'
	);
	$msg->attach(Path => '/home/kate/stat/10032015.xlsx', Disposition => 'attachment', Type => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
	
	$smtp->send(
		from => 'me@home.org',
		to   => 'you@work.org',
		data => $msg->as_string
	);

=head2 How to send message with BIG attachment

It will be not cool to get message with 50 mb attachment into memory before sending.
Fortunately with help of L<MIME::Lite> and L<MIME::Lite::Generator> we can generate
our email by small portions. As you remember C<data> command accepts subroutine reference
as argument, so it will be super easy to send our big email in memory-efficient way

	use MIME::Lite;
	
	my $msg = MIME::Lite->new(
		Type    => 'multipart/mixed',
		From    => 'me@home.org',
		To      => 'you@work.org',
		Subject => 'my home video'
	);
	# Note: MIME::Lite will not load this file into memory
	$msg->attach(Path => '/home/kate/videos/beach.avi', Disposition => 'attachment', Type => "video/msvideo");
	
	my $generator = MIME::Lite::Generator->new($msg);
	
	$smtp->send(
		from => 'me@home.org',
		to   => 'you@work.org',
		data => sub { $generator->get() }
	);

=head2 How to send message directly, without using of MTAs such as sendmail, postfix, exim, ...

Sometimes it is more suitable to send message directly to SMTP server of recipient. For example
if you haven't any MTA available or want to check recipient's server responses (e.g. to know is
such user exists on this server [see L<Mojo::Email::Checker::SMTP>]). First you need to know address
of necessary SMTP server. We'll get it with help of L<Net::DNS>. Then we'll send it as usual

	# will use non-blocking approach in this example
	use strict;
	use MIME::Lite;
	use Net::DNS;
	use Mojo::SMTP::Client;
	use Mojo::IOLoop;
	
	use constant TO => 'oleg@cpan.org';
	
	my $loop = Mojo::IOLoop->singleton;
	my $resolver = Net::DNS::Resolver->new();
	my ($domain) = TO =~ /@(.+)/;
	
	# Get MX records
	my $sock = $resolver->bgsend($domain, 'MX');
	$loop->reactor->io($sock => sub {
		my $packet = $resolver->bgread($sock);
		$loop->reactor->remove($sock);
		
		my @mx;
		if ($packet) {
			for my $rec ($packet->answer) {
				push @mx, $rec->exchange if $rec->type eq 'MX';
			}
		}
		
		# Will try with first or plain domain name if no mx records found
		my $address = @mx ? $mx[0] : $domain;
		
		my $smtp = Mojo::SMTP::Client->new(
			address => $address,
			# it is important to properly identify yourself
			hello   => 'home.org'
		);
		
		my $msg = MIME::Lite->new(
			Type    => 'text',
			From    => 'me@home.org',
			To      => TO,
			Subject => 'Direct email',
			Data    => 'Get it!'
		);
		
		$smtp->on(response => sub {
			# some debug
			my ($smtp, $cmd, $resp) = @_;
			
			print ">>", $Mojo::SMTP::Client::CMD{$cmd}, "\n";
			print "<<", $resp->{code}, " ", join("\n", @{$resp->{messages}}), "\n";
		});
		
		$smtp->send(
			from => 'me@home.org',
			to   => TO,
			data => $msg->as_string,
			quit => 1,
			sub {
				my ($smtp, $resp) = @_;
				
				warn $resp->{error} ? 'Failed to send: '.$resp->{error} :
				                      'Sent successfully with code: ', $resp->{code};
				
				$loop->stop;
			}
		);
	});
	$loop->reactor->watch($sock, 1, 0);
	
	$loop->start;

Note: some servers may check your PTR record, availability of SMTP server
on your domain and so on.

=head1 SEE ALSO

L<Mojo::SMTP::Client::Exception>, L<Mojolicious>, L<Mojo::IOLoop>

=head1 COPYRIGHT

Copyright Oleg G <oleg@cpan.org>.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
