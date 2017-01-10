package AnyEvent::VK;

use 5.010;
use strict;
use warnings;

use AnyEvent::HTTP;
use Async::Chain;
use HTTP::Easy;
use HTTP::Easy::Cookies;
use JSON::XS;
use URI::Escape;

my $JSON = JSON::XS->new->utf8;

use constant {
	OAUTH_URL   => 'https://oauth.vk.com/authorize',
	LOGIN_URL   => 'https://login.vk.com/?act=login&soft=1&utf8=1',
	REQUEST_URL => 'https://api.vk.com/method/',
	REDIRECT_URL => 'https://oauth.vk.com/blank.html',
};

=head1 NAME

AnyEvent::VK a thin wrapper for VK API using OAuth and https

=head1 VERSION

Version 0.02

=cut

our $VERSION = '0.02';


=head1 SYNOPSIS

use utf8;
use AnyEvent;
use AnyEvent::VK;

my $vk = AnyEvent::VK->new(
	app_id    => 'Your APP ID',
	email     => 'Email/Mobile of user',
	password  => 'User Password',
	scope     => 'Application permissions',
);

# scope is Optional; default scope is 'friends,photos,audio,video,wall,groups,messages,offline'
# for more information: https://vk.com/dev/permissions

# Get access_token:
my $cv = AE::cv; cv->begin;
$vk->auth(sub {
	my $success = shift;
	if ($success) {
		my ($token, $expires_in, $user_id) = @_;
		# Do some staff
	} else {
		my ($stage, $headers, $body, $cookie) = @_;
		# $stage could be:
		# 1. oauth. Errors while get OAUTH page
		# 2. login. Errors on user authentification
		# 3. redirect. Errors on redirects. $cookie will be defined
	}
	$cv->end;
});

# If you already have non-expired access_token:
my $vk = AnyEvent::VK->new(
	app_id    => 'Your APP ID',
	email     => 'Email/Mobile of user',
	password  => 'User Password',
	scope     => 'Application permissions',

	token     => 'Your access_token',
	expires   => 'Token expires timestamp',
	user_id   => 'user_id',
);
# Note! Method auth WILL NOT reauthentificate user if token is not expired

=cut

our $REQUEST_TIMEOUT = 3;

sub new {
	my ($self, %args) = @_;

	$args{app_id} or return undef;
	$args{email} or return undef;
	$args{password} or return undef;

	$args{scope} ||= 'friends,photos,audio,video,wall,groups,messages,offline';

	return bless { %args }, 'AnyEvent::VK';
}


sub auth {
	my $self = shift;
	my $cb = pop;

	if ($self->{token} and defined $self->{expires} and $self->{user_id}) {
		if ($self->{expires} == 0 or $self->{expires} > time()) {
			warn 'Token is nonexpired';
			return $cb->(1, $self->{token}, $self->{expires}, $self->{user_id});			
		} else {
			warn 'Token is expired';
		}
	}

	chain
	oauth => sub {
		my $next = shift;
		http_request
			GET => OAUTH_URL . '?' . $self->_hash2url({
				client_id       => $self->{app_id},
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

use AnyEvent;
use AnyEvent::VK;

# Request to API:
my $cv = AE::cv; $cv->begin;
$vk->request('users.get', {
	user_ids => '1,2',
	fields => 'bdate,sex,city,verified',
}, sub {
	my $response = shift;
	if ($response) {
		my $meta = shift;
		# $response is HASH -- decoded JSON
s
	} else {
		my $meta = shift;
		# JSON decode failed or response status not 200
		# $meta = {
		#     headers => ...,
		#     body    => ...,
		# };
	}
	$cv->end;
});

# For more information about methods goto: https://vk.com/dev/methods

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
		timeout => $REQUEST_TIMEOUT,
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
					my ($token)      = $h->{URL} =~ m/access_token=([^&]+)/;
					my ($expires_in) = $h->{URL} =~ m/expires_in=(\d+)/;
					my ($user_id)    = $h->{URL} =~ m/user_id=(\d+)/;

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
	return join '&', map { uri_escape($_) . '=' . uri_escape($h->{$_}) } keys %$h;
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

Please report any bugs or feature requests to C<< <vogrubov at mail.ru> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2017 Vladislav Grubov.
This program is released under the following license: GPL

=cut

1; # End of AnyEvent::VK
