# $Id$

# Rocco's IRC bot stuff.

package Client::IRC;

use strict;

use POE::Session;
use POE::Component::IRC;

use File::Path;
use HTML::Entities;
use IO::AtomicFile;  # TODO: Use this for the forces of good.

# TODO: Move configuration things to ircxom.conf

my %last_by_nick;

use Util::Conf;

# TODO: Move this into a file.  Persistent ignores are good.
my %ignored =
  ( purl      => 1,
    nopaste   => 1,
    pastebot  => 1,
    eatpaste  => 1,
    dipsy     => 1,
    laotse    => 1,
    "perl-fu" => 1,
    cpan      => 1,
  );

my %helptext =
  ( help => <<EOS,
Anything addressed to me that isn't a command will be logged.
Commands: mv, rm, title, ..., .=, url, about, uptime
EOS

    mv => <<EOS,
Usage: mv <#number> <category> where <#number> is the unique number
for a previous entry, and <category> is a relative path to place it in
the blog's namespace.
EOS

    rm => <<EOS,
Usage: rm <#number> deletes a previous entry identified by its unique
number.
EOS

    title => <<EOS,
Usage: title <#number> [<new title>] adds or changes the title of an
existing entry.  A title can be cleared if <new title> is omitted.
EOS

    "..." => <<EOS,
Usage: ... <more text>.  Appends <more text> to your last entry.  If
you are unsure which was your last entry, use += or .= instead.
EOS

    ".=" => <<EOS,
Usage: <#number> .= <more text>.  Appends <more text> to entry
<#number>.
EOS

    url => <<EOS,
Usage: url.  The bot will tell you the URL of its blog.
EOS

    about => <<EOS,
Usage: about.  Tells about the bot.
EOS

    uptime => <<EOS,
Display how long the program has been running and how much CPU it has
consumed.
EOS
  );

# easy to enter, make it suitable to send
for my $key (keys %helptext) {
  $helptext{$key} =~ tr/\n /  /s;
  $helptext{$key} =~ s/\s+$//;
}

my ($base_dir, $blog_url);
foreach my $cur ( get_names_by_type( 'paths' ) ) {
  my %conf = get_items_by_name( $cur );

  $base_dir = $conf{data};
  $base_dir .= '/' unless $base_dir =~ m{/$};

  $blog_url = $conf{url};
}

print STDERR "base_dir $base_dir\n";

#------------------------------------------------------------------------------
# Spawn the IRC session(s).

foreach my $server (get_names_by_type('irc')) {
  my %conf = get_items_by_name($server);

  POE::Component::IRC->new($server);

  POE::Session->create
    ( inline_states =>
      { _start => sub {
          my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];

          $kernel->alias_set( "irc_client_$server" );
          $kernel->post( $server => register => 'all' );

          $heap->{server_index} = 0;

          # Keep-alive timer.
          $kernel->delay( autoping => 300 );

          $kernel->yield( 'connect' );
        },

        autoping => sub {
          my ($kernel, $heap) = @_[KERNEL, HEAP];
          $kernel->post( $server => userhost => $conf{nick} )
            unless $heap->{seen_traffic};
          $heap->{seen_traffic} = 0;
          $kernel->delay( autoping => 300 );
        },

        connect => sub {
          my ($kernel, $heap) = @_[KERNEL, HEAP];

          $kernel->post( $server => connect =>
                         { Debug     => 0,
                           Nick      => $conf{nick},
                           Server    => $conf{server}->[$heap->{server_index}],
                           Port      => 6667,
                           Username  => $conf{uname},
                           Ircname   => $conf{iname},
                           LocalAddr => $conf{localaddr},
                         }
                       );

          $heap->{server_index}++;
          $heap->{server_index} = 0
            if $heap->{server_index} >= @{$conf{server}};
        },

        join => sub {
          my ($kernel, $channel) = @_[KERNEL, ARG0];
          $kernel->post( $server => join => $channel );
        },

        irc_msg => sub {
          my ($kernel, $heap, $sender, $msg) = @_[KERNEL, HEAP, ARG0, ARG2];

          my ($nick) = $sender =~ /^([^!]+)/;
          print "Message $msg from $nick\n";

          my $response = try_all($msg, $server, "msg", $nick, $conf{open});
          $kernel->post($server => privmsg => $nick, $response)
            if defined $response;
        },

        _default => sub {
          my ($state, $event, $args, $heap) = @_[STATE, ARG0, ARG1, HEAP];
          $args ||= [ ];
          print "default $state = $event (@$args)\n";
          $heap->{seen_traffic} = 1;
          return 0;
        },

        irc_001 => sub {
          my ($kernel, $heap) = @_[KERNEL, HEAP];

          if (defined $conf{flags}) {
            $kernel->post( $server => mode => $conf{nick} => $conf{flags} );
          }

          $kernel->post( $server => away => $conf{away} );

          foreach my $channel (@{$conf{channel}}) {
            $kernel->yield( join => "\#$channel" );
          }

          $heap->{server_index} = 0;
        },

        irc_ctcp_version => sub {
          my ($kernel, $sender) = @_[KERNEL, ARG0];
          my $who = (split /!/, $sender)[0];
          print "ctcp version from $who\n";
          $kernel->post( $server => ctcpreply => $who, "VERSION $conf{cver}" );
        },

        irc_ctcp_clientinfo => sub {
          my ($kernel, $sender) = @_[KERNEL, ARG0];
          my $who = (split /!/, $sender)[0];
          print "ctcp clientinfo from $who\n";
          $kernel->post( $server => ctcpreply =>
                         $who, "CLIENTINFO $conf{ccinfo}"
                       );
        },

        irc_ctcp_userinfo => sub {
          my ($kernel, $sender) = @_[KERNEL, ARG0];
          my $who = (split /!/, $sender)[0];
          print "ctcp userinfo from $who\n";
          $kernel->post( $server => ctcpreply =>
                         $who, "USERINFO $conf{cuinfo}"
                       );
        },

        irc_invite => sub {
          my ($kernel, $who, $where) = @_[KERNEL, ARG0, ARG1];
          $kernel->yield( join => $where );
        },

        irc_kick => sub {
          my ($kernel, $who, $where, $isitme, $reason) =
            @_[KERNEL, ARG0..ARG4];
          print "$who was kicked from $where: $reason\n";
        },

        irc_disconnected => sub {
          my ($kernel, $server) = @_[KERNEL, ARG0];
          print "Lost connection to server $server.\n";
          $kernel->delay( connect => 60 );
        },

        irc_error => sub {
          my ($kernel, $error) = @_[KERNEL, ARG0];
          print "Server error occurred: $error\n";
          $kernel->delay( connect => 60 );
        },

        irc_socketerr => sub {
          my ($kernel, $error) = @_[KERNEL, ARG0];
          print "IRC client ($server): socket error occurred: $error\n";
          $kernel->delay( connect => 60 );
        },

        irc_public => sub {
          my ($kernel, $heap, $who, $where, $msg) =
            @_[KERNEL, HEAP, ARG0..ARG2];
          $who = (split /!/, $who)[0];
          $where = $where->[0];
          print "<$who:$where> $msg\n";

          $heap->{seen_traffic} = 1;

          # Ignore certain users.
          return if exists $ignored{lc $who};

          # Ignore if we aren't addressed.
          my $self = $conf{nick};
          return unless $msg =~ s/^\s*$self[\#\)\-\:\>\}\|\,]+\s*//;

          # Do something with input here?
          my $response = try_all($msg, $server, $where, $who, $conf{open});
          $kernel->post($server => privmsg => $where, $response)
            if defined $response;
        },
      }
    );
}

### Helper function.  Display a number of seconds as a formatted
### period of time.  NOT A POE EVENT HANDLER.

sub format_elapsed {
  my ($secs, $precision) = @_;
  my @fields;

  # If the elapsed time can be measured in weeks.
  if (my $part = int($secs / 604800)) {
    $secs %= 604800;
    push(@fields, $part . 'w');
  }

  # If the remaining time can be measured in days.
  if (my $part = int($secs / 86400)) {
    $secs %= 86400;
    push(@fields, $part . 'd');
  }

  # If the remaining time can be measured in hours.
  if (my $part = int($secs / 3600)) {
    $secs %= 3600;
    push(@fields, $part . 'h');
  }

  # If the remaining time can be measured in minutes.
  if (my $part = int($secs / 60)) {
    $secs %= 60;
    push(@fields, $part . 'm');
  }

  # If there are any seconds remaining, or the time is nothing.
  if ($secs || !@fields) {
    push(@fields, $secs . 's');
  }

  # Reduce precision, if requested.
  pop(@fields) while $precision and @fields > $precision;

  # Combine the parts.
  join(' ', @fields);
}

### Do the help stuff.  Used for public and private messages.
sub try_help {
  my ($msg, $net, $channel, $nick, $open) = @_;

  return undef unless $msg =~ /^help(?:\s+(\w+))?$/;
  my $what = $1;
  $what = "help" unless $what;

  return $helptext{$what} if exists $helptext{$what};
  return "There's no help for topic '$what'.";
}

### Generate uptime message.
sub try_uptime {
  my ($msg, $net, $channel, $nick, $open) = @_;

  return undef unless $msg =~ /^\s*uptime\s*$/;

  my ($user_time, $system_time) = (times())[0,1];
  my $wall_time = (time() - $^T) || 1;
  my $load_average = sprintf("%.4f", ($user_time+$system_time) / $wall_time);
  my $response =
    ( "I was started on " . scalar(gmtime($^T)) . " GMT. " .
      "I've been active for " . format_elapsed($wall_time, 2) . ". " .
      sprintf( "I have used about %.2f%% of a CPU during my lifespan.",
               (($user_time+$system_time)/$wall_time) * 100
             )
    );
}

### Try the url command.
sub try_url {
  my ($msg, $net, $channel, $nick, $open) = @_;
  return "I should be at $blog_url"
    if $msg =~ /^url\??$/;
  return undef;
}

### Say something about the bot.
sub try_about {
  my ($msg, $net, $channel, $nick, $open) = @_;
  return undef unless $msg =~ /^about\??$/;
  return ( "Ircxom is an experiment in group IRC logging.  " .
           "It allows users of IRC channels to add and maintain " .
           "entries in a blosxom web log."
         );
}

### Append to a numbered thingy.
sub try_num {
  my ($msg, $net, $channel, $nick, $open) = @_;

  return undef unless $msg =~ /^\#(\d+)\s*(?:[\.\+]=)?\s*(.*)$/;
  my ($number, $message) = ($1, $2);

  my $fqfn = _file_find($number);
  return "Entry \#$number doesn't seem to exist anymore."
    unless $fqfn;

  my $old_nick = eval { _get_nick($fqfn) };
  return $@->[0] if $@;

  unless ($open or lc($nick) eq lc($old_nick)) {
    return "You didn't write entry \#$number.";
  }

  my $safe_message = encode_entities($message);
  if ($safe_message eq "") {
    $safe_message = "<p>";
  }

  open(ENTRY, ">>$fqfn") or return "Can't append to $fqfn: $!";
  print ENTRY " $safe_message";
  close ENTRY;

  $last_by_nick{$nick} = $number;

  if ($safe_message eq "<p>") {
    return "Appended paragraph break to \#$number.";
  }

  return "Appended to \#$number.";
}

### Retitle a thingy.
sub try_title {
  my ($msg, $net, $channel, $nick, $open) = @_;

  return undef unless $msg =~ /^title\s*\#(\d+)\s*(?:[\.\+]=)?\s*(.*)/;
  my ($number, $new_title) = ($1, $2);

  my $fqfn = _file_find($number);
  return "Entry \#$number doesn't seem to exist anymore."
    unless $fqfn;

  my $old_nick = eval { _get_nick($fqfn) };
  return $@->[0] if $@;

  unless ($open or lc($nick) eq lc($old_nick)) {
    return "You didn't write entry \#$number.";
  }

  open(ENTRY, "<$fqfn") or return "Can't read $fqfn: $!";
  my $title = <ENTRY>;
  chomp $title;
  local $/;
  my $body = <ENTRY>;
  close ENTRY;

  $title =~ s/ - .*//;
  if (length $new_title) {
    $title .= encode_entities(" - $new_title");
  }

  open(ENTRY, ">$fqfn.new") or return "Can't write $fqfn.new: $!";
  print ENTRY "$title\n$body";
  close ENTRY;

  rename($fqfn, "$fqfn.old")
    or return "Can't rename $fqfn -> $fqfn.old: $!";

  unless (rename("$fqfn.new", $fqfn)) {
    rename("$fqfn.old", $fqfn)
      or return "Can't restore $fqfn.old -> $fqfn (restore manually): $!";
    return "Can't rename $fqfn.new -> $fqfn (changes lost): $!";
  }

  unlink("$fqfn.old") or
    return "Can't remove $fqfn.old (clean up manually): $!";

  return "Title changed." if length $new_title;
  return "Title cleared.";
}

### Remove a thingy.
sub try_remove {
  my ($msg, $net, $channel, $nick, $open) = @_;

  return undef unless $msg =~ /^rm\s*\#(\d+)/;
  my $number = $1;

  my $fqfn = _file_find($number);
  return "Entry \#$number doesn't seem to exist anymore."
    unless $fqfn;

  my $old_nick = eval { _get_nick($fqfn) };
  return $@->[0] if $@;

  unless ($open or lc($nick) eq lc($old_nick)) {
    return "You didn't write entry \#$number.";
  }

  unlink($fqfn) or return "Can't remove $fqfn: $!";
  return "Entry \#$number removed.";
}

### Rename a thingy.
sub try_rename {
  my ($msg, $net, $channel, $nick, $open) = @_;

  return undef unless $msg =~ /^mv\s*\#(\d+)\s*(\S+)(.*?)$/;
  my ($number, $new_rel_path, $syntax_error) = ($1, $2, $3);
  if (defined $syntax_error and length $syntax_error) {
    return "Nothing should come after the new relative path.";
  }

  if ($new_rel_path =~ /[^a-zA-Z0-9\/]/) {
    return "Relative paths can only be letters, numbers, and /.";
  }

  my $fqfn = _file_find($number);
  return "Entry \#$number doesn't seem to exist."
    unless $fqfn;

  $new_rel_path =~ s/\/+/\//g;
  $new_rel_path =~ s/\.\.*/_/g;

  my $new_path = $base_dir . "/" . $new_rel_path;
  $new_path =~ s/\/+/\//g;
  $new_path =~ s/\/$//;  # No trailing /

  mkpath($new_path, 0, 0755);
  return "Can't make path $new_path: $!" unless -d $new_path;

  my $new_fqfn = $new_path . "/irc-$number.txt";
  rename($fqfn, $new_fqfn) or return "Can't move $fqfn -> $new_fqfn: $!";

  return "Entry \#$number moved to category $new_rel_path.";
}

### Append to a thingy.
sub try_applast {
  my ($msg, $net, $channel, $nick, $open) = @_;

  return undef unless $msg =~ /^\.\.\.\s*(.*)$/;
  my $message = $1;

  my $number  = $last_by_nick{$nick};
  return "I don't remember your last entry.  Use #number .= stuff instead."
    unless defined $number;

  my $fqfn = _file_find($number);
  return "Entry \#$number doesn't seem to exist anymore."
    unless $fqfn;

  my $safe_message = encode_entities($message);
  if ($safe_message eq "") {
    $safe_message = "<p>";
  }

  open(ENTRY, ">>$fqfn") or return "Can't append to $fqfn: $!";
  print ENTRY "\n$safe_message";
  close ENTRY;

  $last_by_nick{$nick} = $number;

  if ($safe_message eq "<p>") {
    return "Appended paragraph break to \#$number.";
  }

  return "Appended to \#$number.";
}

### Create a thingy.
sub try_create {
  my ($msg, $net, $channel, $nick, $open) = @_;

  my $next_file = $base_dir . "ircxom.seqnum";
  unless (-e $next_file) {
    open(SEQ, ">$next_file") or die "Can't create $next_file: $!";
    print SEQ "1\n";
    close SEQ;
  }

  open(SEQ, "<$next_file") or return "Can't read $next_file: $!";
  my $next = <SEQ>;
  close SEQ;
  chomp $next;

  my $log_dir = $base_dir . "irc/$net/$channel";

  unless (-e $log_dir) {
    mkpath($log_dir, 0, 0755);
    return "Can't make path $log_dir: $!" unless -d $log_dir;
  }

  my $file = "$log_dir/irc-$next.txt";
  while (-e $file) {
    $next++;
    $file = "$log_dir/irc-$next.txt";
  }

  open(SEQ, ">$next_file") or return "Can't write $next_file: $!";
  print SEQ $next+1;
  close SEQ;

  open(ENTRY, ">$file") or return "Can't write to $file: $!";
  print ENTRY "$nick\n" . encode_entities($msg);
  close(ENTRY);

  $last_by_nick{$nick} = $next;

  return "Logged as \#$next.";
}

### Helper.  Process a list of commands.
sub try_all {
  my ($msg, $net, $channel, $nick, $open) = @_;
  my $response;

  # Clean up input.
  $msg =~ s/\s+/ /g;
  $msg =~ s/^\s+//;
  $msg =~ s/\s+$//;

  $channel =~ s/\/+/-/g;
  $channel =~ s/\.\.*/_/g;
  $channel = "private" unless $channel;

  # Try things.
  $response = try_uptime($msg, $net, $channel, $nick, $open);
  return $response if defined $response;

  $response = try_help($msg, $net, $channel, $nick, $open);
  return $response if defined $response;

  $response = try_about($msg, $net, $channel, $nick, $open);
  return $response if defined $response;

  $response = try_url($msg, $net, $channel, $nick, $open);
  return $response if defined $response;

  $response = try_num($msg, $net, $channel, $nick, $open);
  return $response if defined $response;

  $response = try_title($msg, $net, $channel, $nick, $open);
  return $response if defined $response;

  $response = try_remove($msg, $net, $channel, $nick, $open);
  return $response if defined $response;

  $response = try_rename($msg, $net, $channel, $nick, $open);
  return $response if defined $response;

  $response = try_applast($msg, $net, $channel, $nick, $open);
  return $response if defined $response;

  # This should go last, as it's the default action and will almost
  # always return something positive.
  $response = try_create($msg, $net, $channel, $nick, $open);
  return $response if defined $response;

  return;
}

# Parse the nick out of an existing file.
sub _get_nick {
  my $fqfn = shift;

  open(ENTRY, "<$fqfn") or die [ "Can't read from $fqfn: $!" ];
  my $nick = <ENTRY>;
  close ENTRY;

  chomp $nick;
  $nick =~ s/ - .*//;

  return $nick;
}

# Return the fully qualified filename for an article by number.
sub _file_find {
  my $number = shift;

  my $file_name = "irc-$number.txt";
  my $command = "/usr/bin/find " . $base_dir . " -type f -name $file_name";
  my @fqfn = `$command`;

  return undef unless @fqfn == 1;
  my $fqfn = $fqfn[0];
  chomp $fqfn;
  return $fqfn;
}

#------------------------------------------------------------------------------
1;
