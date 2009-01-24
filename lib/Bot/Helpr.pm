package Bot::Helpr;
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
);

has password => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has aim => (
  is       => 'ro',
  isa      => 'POE::Component::OSCAR',
  lazy     => 1,
  init_arg => undef,
  default  => sub {
    POE::Component::OSCAR->new(
      throttle     => 1,
      capabilities => [ qw(buddy_icons) ],
    )
  },
);

has buddy_icon => (
  is       => 'ro',
  isa      => 'Str',
);

has default_time_zone => (
  is       => 'ro',
  default  => 'America/New_York',
);

has date_parser => (
  is       => 'ro',
  isa      => 'DateTime::Format::Natural',
  lazy     => 1,
  default  => sub {
    return DateTime::Format::Natural->new(
      prefer_future => 1,
      time_zone     => $_[0]->default_time_zone,
    );
  },
);

has default_location => (
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
Hi, I'm HELPR!

I respond to the following:
  date
  time
  time in <location>
  weather <location>
  =<math>
  change X to Y (change currency)
  convert X to Y (convert units)
  at DATE/TIME, REMINDER
  in DURATION, REMINDER
END_HELP

  $HELP_TEXT =~ s{\n}{<br />}g;
  $HELP_TEXT =~ s{(<br />)\s+}{$1&nbsp;&nbsp;}g;
}

event signon_done => sub {
  my ($self) = @_[OBJECT,];

  warn "Signon done!\n";

  if (my $ico = $self->buddy_icon) {
    my $ok = eval {
      open my $fh, '<', $ico or die "couldn't open icon file $ico: $!";

      # we're limited to this size anyway
      die "couldn't read from icon file: $!"
        unless sysread $fh, my($icondata), 4096;

      $self->aim->set_icon($icondata);
      $self->aim->commit_buddylist;
      1;
    };

    unless ($ok) {
      warn "couldn't set buddy icon: $@";
    }
  }

};

my @commands;
BEGIN {
  @commands = (
    qr/help/                    => sub { $HELP_TEXT },
    qr/help\s+.+/               => sub { 'Sorry, no extended help yet!' },

    qr/w(?:eather)?(?:\.)?/     => 'weather',
    qr/w(?:eather)? (?<loc>.+)/ => 'weather',

    qr/(?:time|date)/               => '__now',
    qr/(?:time|date) in (?<loc>.+)/ => 'time_in',

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

  my $query;
  if ($arg->{calc}) {
    $query = $arg->{calc};
  } elsif ($arg->{from} and $arg->{to}) {
    $query = "$arg->{from} in $arg->{to}";
  } else {
    die "didn't know how to perform calculation";
  }

  my $result = WWW::Google::Calculator->new->calc($query);

  return $result || "no response for: $query";
}

sub __now { DateTime->now(time_zone => $_[0]->default_time_zone) }

sub __fc {
  my ($f) = @_;
  my $c = int(($f - 32) * 5/9);
  sprintf '%s F (%s C)', $f, $c;
}

sub reminder_in {
  my ($self, $arg) = @_;
  my ($duration, $desc) = @$arg{qw(duration message)};

  die "couldn't understand duration: $duration"
    unless my $secs = parse_duration($duration);

  my $time = DateTime->from_epoch(
    epoch     => time + $secs,
    time_zone => $self->default_time_zone,
  );

  $poe_kernel->delay_add(reminder => $secs => $arg->{WHO}, $desc, $self->__now);

  return "Okay, at $time, I'll give you that reminder.";
}

sub reminder_at {
  my ($self, $arg) = @_;
  my ($time_str, $desc) = @$arg{qw(datetime message)};

  my $datetime = $self->date_parser->parse_datetime($time_str)
    or die "couldn't parse datetime: " . $self->date_parser->error;

  $poe_kernel->alarm_add(
    reminder => $datetime->epoch => $arg->{WHO}, $desc, $self->__now
  );

  return "Okay, at $datetime, I'll give you that reminder.";
}

sub weather {
  my ($self, $arg) = @_;
  my $loc = $arg->{loc} || $self->default_location;
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

sub time_in {
  my ($self, $arg) = @_;
  my $loc = $arg->{loc};

  require WWW::Mechanize;
  require WWW::Mechanize::TreeBuilder;

  my $mech = WWW::Mechanize->new;
  my $url  = sprintf
    'http://www.timeanddate.com/worldclock/results.html?query=%s',
    $loc;

  return "I couldn't find the local time for there, sorry."
    unless $mech->get($url)->is_success;

  return "I couldn't find the local time for there, sorry."
    unless my $link = $mech->find_link(url_regex => qr/^city\.html\?n=/);

  WWW::Mechanize::TreeBuilder->meta->apply($mech);
  return "I couldn't find the local time for there, sorry."
    unless $mech->get($link->url)->is_success;

  my ($name) = $mech->look_down(class => 'biggest');
  my ($time) = $mech->look_down(id    => 'ct');
  my ($tz  ) = $mech->look_down(id    => 'cta');

  return sprintf q{Right now in %s it's %s%s.},
    (map { $_->as_text } $name, $time),
    ($tz ? (' ' . $tz->as_text) : '');
}
  
event reminder => sub {
  my ($self, $target, $text, $setup_time) = @_[OBJECT,ARG0,ARG1,ARG2];

  my $message = "Reminder: $text<br />(requested at $setup_time)";
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

  warn "MESSAGE <$what> from <$who>\n";
  
  for (my $i = 0; $i < @commands; $i += 2) {
    my ($re, $cmd) = @commands[ $i, $i + 1 ];

    if ($what =~ /\A$re\z/i) {
      my %arg = (%+, WHO => $who);

      my $reply = eval { $self->$cmd(\%arg) };
      return warn "error with <$what>: $@\n" unless $reply;
      $self->aim->send_im($who => $reply);
      return;
    }
  }

  $self->aim->send_im($who => "I didn't understand that.  Try <i>help.</i>");
};

1;
