package Helpr::Bot;
use MooseX::POE;

use DateTime;
use DateTime::Format::Natural;
use HTML::TreeBuilder;
use POE qw(Component::OSCAR);
use Time::Duration::Parse qw(parse_duration);
use Weather::Google;
use WWW::Google::Calculator;

has username => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
  default  => q{helpr@codesimply.com},
);

has password => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
  default  => ';2}EL2Nf2U6.&;4q',
);

has aim => (
  is       => 'ro',
  isa      => 'POE::Component::OSCAR',
  lazy     => 1,
  init_arg => undef,
  default  => sub { POE::Component::OSCAR->new(throttle => 1) },
);

has date_parser => (
  is       => 'ro',
  isa      => 'DateTime::Format::Natural',
  lazy     => 1,
  default  => sub { DateTime::Format::Natural->new(prefer_future => 1) },
);

has location => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
  default  => '18018',
);

sub START {
  my ($self) = @_[OBJECT,];

  # Oscar's 'signon_done' callback will call our state, 'signon_done', etc.
  # See the Net::OSCAR docs for all the possible callbacks
  $self->aim->set_callback(signon_done => 'signon_done');
  $self->aim->set_callback(im_in => 'im_in');

  # $self->aim->set_callback( error => 'error' );
  # $self->aim->set_callback( admin_error => 'admin_error' );
  # $self->aim->set_callback( rate_alert => 'rate_alert' );

  $self->aim->loglevel(5);

  $self->aim->signon(
    screenname => $self->username,
    password   => $self->password,
  );
}

my $HELP_TEXT;
BEGIN {
  $HELP_TEXT = <<'END_HELP';
Hi.  I'm HELPR.

I respond to the following:
 date
 w <location>
 =<math>
 change X to Y (change currency)
 convert X to Y (convert units)
 at DATE/TIME, REMINDER
 in DURATION, REMINDER
END_HELP
}

event signon_done => sub {
  print "Signon done!\n";
};

my @commands;
BEGIN {
  @commands = (
    qr/help/                    => sub { $HELP_TEXT },
    qr/date/                    => sub { __now()    },
    qr/w(?:eather)?(?:\.)?/     => 'weather',
    qr/w(?:eather)? (?<loc>.+)/ => 'weather',

    qr/=(?<calc>.+)/                      => 'calc',
    qr/convert (?<from>.+?) to (?<to>.+)/ => 'calc',
    qr/change (?<from>.+?) to (?<to>.+)/  => 'calc',

    qr/in (?<duration>[^,]+?),\s*(?<message>.+)/ => 'reminder_in',
    qr/at (?<datetime>[^,]+?),\s*(?<message>.+)/ => 'reminder_at',

    qr/.*(?:fuck|shit).*/
      => sub { 'Such language in a high-class establishment like this!' },
  );
}

sub calc {
  my ($self, $arg) = @_;
  my $query  = $arg->{query};
  my $result = WWW::Google::Calculator->new->calc($query);

  return $result || "no response for: $query";
}

sub __now { DateTime->now(time_zone => 'UTC') }

sub __fc {
  my ($f) = @_;
  my $c = int(($f - 32) * 5/9);
  sprintf '%s F (%s C)', $f, $c;
}

sub reminder_in {
  my ($self, $arg) = @_;
  my ($duration, $desc) = @$arg{qw(duration message)};

  my $secs = parse_duration($duration);
  my $time = localtime time + $secs;

  $poe_kernel->delay_add(reminder => $secs => $arg->{WHO}, $desc, __now);

  return "Okay, at $time, I'll give you that reminder.";
}

sub reminder_at {
  my ($self, $arg) = @_;
  my ($time_str, $desc) = @$arg{qw(datetime message)};

  my $datetime = $self->date_parser->parse_datetime($time_str)
    or die "couldn't parse datetime: " . $self->date_parser->error;

  $poe_kernel->alarm_add(
    reminder => $datetime->epoch => $arg->{WHO}, $desc, __now
  );

  my $time = localtime $datetime->epoch;
  return "Okay, at $time, I'll give you that reminder.";
}

sub weather {
  my ($self, $arg) = @_;
  my $loc = $arg->{loc} || $self->location;
  my $weather = Weather::Google->new($loc);

  return "I couldn't find the weather for that location."
    unless $weather->current->{condition};

  my $cur = $weather->current;
  my $reply = sprintf "In %s, it's currently %s.  %s.  %s.",
    $weather->forecast_information('city'),
    __fc($cur->{temp_f}),
    $cur->{wind_condition},
    $cur->{condition};

  my $tom = $weather->forecast(1);
  $reply .= sprintf "\nTomorrow, we expect a low of %s and a high of %s.  Expected conditions: %s.",
    __fc($tom->{low}), __fc($tom->{high}), lc($tom->{condition});

  return $reply;
}

event reminder => sub {
  my ($self, $target, $text, $setup_time) = @_[OBJECT,ARG0,ARG1,ARG2];

  my $message = "Here is the reminder you requested at $setup_time:\n$text";
  $self->aim->send_im($target => $message);
};

event im_in => sub {
  # first arg is empty; see the Net::OSCAR module for details about
  # the other arguments
  my ($self, $args) = @_[OBJECT,ARG1];
  my ($object, $who, $what, $away) = @$args;

  $what = HTML::TreeBuilder->new_from_content($what)->as_text;
  $what =~ s{(?:^\s+|\s+$)}{}g;
  $what =~ s{\s{2,}}{ };

  print "MESSAGE <$what> from <$who>\n";
  
  for (my $i = 0; $i < @commands; $i += 2) {
    my ($re, $cmd) = @commands[ $i, $i + 1 ];

    if ($what =~ /\A$re\z/i) {
      my %arg = (%+, WHO => $who);

      my $reply = eval { $self->$cmd(\%arg) };
      return print "error with <$what>: $@\n" unless $reply;
      $self->aim->send_im($who => $reply);
      return;
    }
  }

  print "Ignored msg from $who: $what\n";
};

1;
