use warnings;
use strict;
use Test::More;
use HTTP::Request::Common;
use HTTP::Message::PSGI;
use Plack::Util;
use Plack::Test;

# Test to make sure HTTP style exceptions do NOT bubble up to the middleware
# if the backcompat setting 'always_catch_http_exceptions' is enabled.

{
  package MyApp::Exception;

  sub new {
    my ($class, $code, $headers, $body) = @_;
    return bless +{res => [$code, $headers, $body]}, $class;
  }

  sub throw { die shift->new(@_) }

  sub as_psgi {
    my ($self, $env) = @_;
    my ($code, $headers, $body) = @{$self->{res}};

    return [$code, $headers, $body]; # for now

    return sub {
      my $responder = shift;
      $responder->([$code, $headers, $body]);
    };
  }

  package MyApp::AnotherException;

  sub new { bless +{}, shift }

  sub code { 400 }

  sub as_string { 'bad stringy bad' }

  package MyApp::Controller::Root;

  use base 'Catalyst::Controller';

  my $psgi_app = sub {
    my $env = shift;
    die MyApp::Exception->new(
      404, ['content-type'=>'text/plain'], ['Not Found']);
  };

  sub from_psgi_app :Local {
    my ($self, $c) = @_;
    $c->res->from_psgi_response(
      $psgi_app->(
        $c->req->env));
  }

  sub from_catalyst :Local {
    my ($self, $c) = @_;
    MyApp::Exception->throw(
      403, ['content-type'=>'text/plain'], ['Forbidden']);
  }

  sub from_code_type :Local {
    my $e = MyApp::AnotherException->new;
    die $e;
  }

  sub classic_error :Local {
    my ($self, $c) = @_;
    Catalyst::Exception->throw("Ex Parrot");
  }

  sub just_die :Local {
    my ($self, $c) = @_;
    die "I'm not dead yet";
  }

  package MyApp;
  use Catalyst;

  MyApp->config(
      abort_chain_on_error_fix=>1,
      always_catch_http_exceptions=>1,
  );

  sub debug { 1 }

  MyApp->setup_log('fatal');
}

$INC{'MyApp/Controller/Root.pm'} = __FILE__; # sorry...
MyApp->setup_log('error');

Test::More::ok(MyApp->setup);

ok my $psgi = MyApp->psgi_app;
test_psgi $psgi, sub {
    my $cb = shift;
    my $res = $cb->(GET "/root/from_psgi_app");
    is $res->code, 500;
    like $res->content, qr/MyApp::Exception=HASH/;
};

test_psgi $psgi, sub {
    my $cb = shift;
    my $res = $cb->(GET "/root/from_catalyst");
    is $res->code, 500;
    like $res->content, qr/MyApp::Exception=HASH/;
};

test_psgi $psgi, sub {
    my $cb = shift;
    my $res = $cb->(GET "/root/from_code_type");
    is $res->code, 500;
    like $res->content, qr/MyApp::AnotherException=HASH/;
};

test_psgi $psgi, sub {
    my $cb = shift;
    my $res = $cb->(GET "/root/classic_error");
    is $res->code, 500;
    like $res->content, qr'Ex Parrot', 'Ex Parrot';
};

test_psgi $psgi, sub {
    my $cb = shift;
    my $res = $cb->(GET "/root/just_die");
    is $res->code, 500;
    like $res->content, qr'not dead yet', 'not dead yet';
};

# We need to specify the number of expected tests because tests that live
# in the callbacks might never get run (thus all ran tests pass but not all
# required tests run).

done_testing(12);
