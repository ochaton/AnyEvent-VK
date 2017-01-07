package AnyEvent::VK;

use 5.010;
use strict;
use warnings;

use AnyEvent::HTTP;
use Async::Chain;
use HTTP::Easy;
use HTTP::Easy::Cookies;
use JSON::XS;

my $JSON = JSON::XS->new->utf8;

use constant {
	OAUTH_URL   => 'https://oauth.vk.com/authorize',
	LOGIN_URL   => 'https://login.vk.com/?act=login&soft=1&utf8=1',
	REQUEST_URL => 'https://api.vk.com/method/',
	REDIRECT_URL => 'https://oauth.vk.com/blank.html',
};

=head1 NAME

AnyEvent::VK - The great new AnyEvent::VK!

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

	use AnyEvent::VK;

	my $foo = AnyEvent::VK->new();
	...

=head1 SUBROUTINES/METHODS

=head2 new

=cut

sub new {
	my ($self, %args) = @_;

	$args{api_id} or return undef;
	$args{email} or return undef;
	$args{password} or return undef;

	$args{scope} ||= 'friends,photos,audio,video,wall,groups,messages,offline';

	return bless { %args }, 'AnyEvent::VK';
}

=head2 auth

=cut

sub auth {
	my $self = shift;
	my $cb = pop;

	chain
	oauth => sub {
		my $next = shift;
		http_request
			GET => OAUTH_URL . '?' . $self->_hash2url({
				client_id       => $self->{api_id},
				display         => 'page',
				redirect_uri    => REDIRECT_URL,
				scope           => $self->{scope},
				response_type   => 'token',
			}),
			sub {
				my ($b, $h) = @_;
				return $cb->(undef, 'oauth', $h, $b) if ($h->{Status} != 200);

				my ($form) = $b =~ m/(<form method.+<\/form>)/is;
				my ($orig) = $form =~ m/_origin" value="([^"]+)"/is;
				my ($ip_h) = $form =~ m/ip_h" value="([^"]+)"/is;
				my ($lg_h) = $form =~ m/lg_h" value="([^"]+)"/is;
				my ($to)   = $form =~ m/to" value="([^"]+)"/is;

				my $form_data = {
					_orig   => $orig,
					ip_h    => $ip_h,
					lg_h    => $lg_h,
					to      => $to,
					email   => $self->{email},
					pass    => $self->{password},
					expire  => 0,
				};

				my $query = $self->_hash2url($form_data);

				my $cookie = HTTP::Easy::Cookies->decode($h->{'set-cookie'});
				delete $cookie->{'.vk.com'}{'/'}{'remixstid'};

				my $cookie_string = HTTP::Easy::Cookies->encode($cookie, host => '.login.vk.com') // "";
				$cookie_string =~ s/"//g;

				$next->($cookie_string, $query);
			}
		;
	},
	login => sub {
		my $next = shift;
		my $cookie_string = shift;
		my $query = shift;

		http_request
			POST => LOGIN_URL,
			recurse => 0,
			body => $query,
			headers => {
				'user-agent' => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/55.0.2883.75 Safari/537.36',
				'content-length' => length $query,
				'content-type' => 'application/x-www-form-urlencoded',
				cookie => $cookie_string,
			},
			sub {
				my ($b, $h) = @_;

				if ($h->{Status} != 302) {
					return $cb->(undef, 'login', $h, $b);
				}

				return $self->_redirect($h->{location}, HTTP::Easy::Cookies->decode($h->{'set-cookie'}), $cookie_string, $cb);
			}
		;
	};
}

=head2 request

=cut

sub request {
	my $self = shift;
	my $cb = pop;

	my ($method, $args) = @_;
	$args //= {};

	# API Request is:
	# https://api.vk.com/method/METHOD_NAME?PARAMETERS&access_token=ACCESS_TOKEN&v=V 

	$args->{access_token} = $self->{token};
	my $qparams = $self->_hash2url($args);

	http_request
		GET => REQUEST_URL . "$method?" . $qparams,
		timeout => 3,
		sub {
			my ($body, $hdr) = @_;

			my $response = eval {
				$JSON->decode($body);
			}; if ($@) {
				warn 'JSON Decode failed';
				return $cb->(undef, { body => $body, headers => $hdr});
			}

			return $cb->($response, { headers => $hdr });
		}
	;
}


sub _redirect {
	my ($self, $url, $http_easy_cookie, $raw_cookie, $cb) = @_;
	my $cookie_string = $self->_merge_cookies($http_easy_cookie, $raw_cookie);

	http_request
		GET => $url,
		recurse => 0,
		headers => {
			'user-agent' => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/55.0.2883.75 Safari/537.36',
			cookie => $cookie_string,
		},
		sub {
			my ($b, $h) = @_;

			if ($h->{Status} == 302) {
				return $self->_redirect($h->{location}, HTTP::Easy::Cookies->decode($h->{'set-cookie'}), $cookie_string, $cb);
			} elsif ($h->{Status} == 200) { # Here available 2 variants:
				if ($b =~ m{function allow(.+)return false}gs){ # We need Grant Access to Application
					my ($href) = $1 =~ m/location\.href[^"]*"([^"]+)"/;
					return $self->_redirect($href, HTTP::Easy::Cookies->decode($h->{'set-cookie'}), $cookie_string, $cb);
				} else { # Seemed that we already catch access_token
					$h->{URL} =~ m/#access_token=([^&]+)&expires_in=(\d+)&user_id=(\d+)/;
					my ($token)   = $h->{URL} =~ m/access_token=([^&]+)/;
					my ($expires_in) = $h->{URL} =~ m/expires_in=(\d+)/;
					my ($user_id) = $h->{URL} =~ m/user_id=(\d+)/;

					if (defined $token) {
						$self->{token} = $token;
						$self->{user_id} = $user_id;
						$self->{expires} = time() + $expires_in;
						return $cb->(1, $token, $expires_in, $user_id);
					} else {
						return $cb->(undef, 'redirect', $h, $b, $cookie_string);
					}
				}
			} else {
				return $cb->(undef, 'redirect', $h, $b, $cookie_string);
			}
		}
	;
}

sub _hash2url {
	my $self = shift;
	my $h = shift;
	return join '&', map { $_ . '=' . $h->{$_} } keys %$h;
}

sub _merge_cookies {
	my ($self, $easy_cookie, $raw_cookie) = @_;

	my $cookie_string = '';
	if ($easy_cookie->{'.vk.com'}) {
		$cookie_string .= join '; ', map { $_ . '=' . $easy_cookie->{'.vk.com'}{'/'}{$_}{value} } keys %{$easy_cookie->{'.vk.com'}{'/'}};
	}
	if ($easy_cookie->{'.login.vk.com'}) {
		$cookie_string .= join '; ', map { $_ . '=' . $easy_cookie->{'.login.vk.com'}{'/'}{$_}{value} } keys %{$easy_cookie->{'.login.vk.com'}{'/'}};
	}

	$cookie_string .= '; ' . $raw_cookie if ($raw_cookie);
	$cookie_string =~ s/"//g;

	my %jar = ();
	for (split '; ', $cookie_string) {
		my ($k,$v) = split '=', $_;
		$jar{$k} = $v if ($k);
	}

	$cookie_string = join '; ', map { $_ . '=' . $jar{$_} } grep { $jar{$_} ne 'DELETED' } keys %jar;
	return $cookie_string;
}

=head1 AUTHOR

Vladislav Grubov, C<< <vogrubov at mail.ru> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-anyevent-vk at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=AnyEvent-VK>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

	perldoc AnyEvent::VK


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=AnyEvent-VK>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/AnyEvent-VK>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/AnyEvent-VK>

=item * Search CPAN

L<http://search.cpan.org/dist/AnyEvent-VK/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2017 Vladislav Grubov.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1; # End of AnyEvent::VK
