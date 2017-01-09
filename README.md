# AnyEvent-VK
Asynchronous  wrapper of VK API with minimum requirenments

# Install
perl Makefile.PL
make
make test
make install

# Usage
Here goes some examples

## Example #1
```perl

use AnyEvent;
use AnyEvent::VK;
my $vk = AnyEvent::VK->new(
    app_id    => 'Your APP ID',
    email     => 'Email/Mobile of user',
    password  => 'User Password',
    scope     => 'Application permissions',
);

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

$cv->recv;
```

## Example #2
```perl
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
# Note! Method `auth` WILL NOT reauthentificate user if token is not expired
```

# Make request to VK API
```perl
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
```

# AnyEvent::VK Methods

## new -- Create new AnyEvent::VK object
**Arguments:**
* app_id -- Required. Your AppID;
* email -- Required. User email/phone;
* password -- Required. User password;
* scope -- Optional. Default is 'friends,photos,audio,video,wall,groups,messages,offline';
* token -- Optional. Non-expired access_token;
* expires -- Optional. Timestamp when token will expires;
* user_id -- Optional. user which handles all requests. Necessary for `token` and `expires`

## auth -- Start authentification
Initiate geting new access_token if previous expired or absent
* callback

### Returns:
1. If success => (1, token, expires, user_id)
2. If error   => (undef, stage, headers, body, cookies)
Stage can be one of:
* oauth:
    It failed while getting OAuth page. cookie will be absent
* login:
    User authentification failed. Check email/password first
* redirect:
    It failed on setting/unsetting cookies and multiple redirects.
    If you catch 401 in headers, just try again. Seemed that its internal VK API bug.

## request -- Starts API Request
* method -- Required. Scalar. API method;
* arguments -- Optional. Hashref. Arguments for method;
* callback -- Required.

### Returns:
1. If success => `(DecodedJson, { headers => $hdr })`
2. If failure => `(undef, { body => $body, headers => $hdr })`



