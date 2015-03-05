package Mojo::SMTP::Client::Exception;
use Mojo::Base 'Mojo::Exception';

package Mojo::SMTP::Client::Exception::Stream;
use Mojo::Base 'Mojo::SMTP::Client::Exception';

package Mojo::SMTP::Client::Exception::Response;
use Mojo::Base 'Mojo::SMTP::Client::Exception';
has 'code';
sub throw { die shift->new->code(shift)->trace(2)->_detect(@_) }

1;
