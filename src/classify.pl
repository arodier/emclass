package Amavis::Custom;
use strict;
use warnings;

# First added header: X-Email-Type
# Try to classify email by many type:
# Internal  : same or similar domain for the sender and the recipient
# Private   : private email, between two companies. Should not be a mailing list or something.
# List      : proper mailing list, with standard headers
# Bulk      : bulk email
# Unknown   : faile to classify

# put your internal domains here.
my @local_domains_acl = ( 'exemple.com', 'exemple.org' );

# A set of headers used by bulk emails
my @bulk_headers = ( 'X-Google-Appengine-App-Id' );

# Maybe: Bulk email classificatino are added as 'tags'
# social: social networks, e.g facebook, linkedin, etc.
# order:  
# travel: 
# advertisement: generic advertisement

my $debug = 1;

if ( $debug ) {
  use Data::Dumper;
}

sub new {

  my($class,$conn,$msginfo) = @_;
  my $self = bless {}, $class;
  my $type_header = 'X-Email-Type';
  my $type_reason_header = 'X-Email-Type-Detected-By';
  my $type_value = 'Unknown';
  my $hdr_edits = $msginfo->header_edits;
  my $user;
  my $domain;
  my $internal;
  my @recips;

  # Basic tests
  my $content_type   = $msginfo->get_header_field_body('content-type');
  my @content_type_info = split(/;/, $content_type);
  $content_type = shift(@content_type_info);
  my $is_text = $content_type ~~ /text\/plain/;

  # This will be added into the headers
  my $reason = '';

  eval {

    # Read info about the email
    my $sender         = $msginfo->sender;  # envelope sender address, e.g. 'usr@e.com'
    my $mailer         = $msginfo->get_header_field_body('x-mailer');
    my $log_id         = $msginfo->log_id;       # log ID string, e.g. '48262-21-2'
    my $mail_id        = $msginfo->mail_id;      # long-term unique id, e.g. 'yxqmZgS+M09R'
    my $mail_size      = $msginfo->msg_size;     # mail size in bytes

    my $tempdir        = $msginfo->mail_tempdir;  # working directory for this process
    my $mail_file_name = $msginfo->mail_text_fn;

    @recips         = $msginfo->recips;

    # Check internal email first
    ($user,$domain) = split(/@/, $sender);
    $internal = scalar grep /$domain/, @local_domains_acl;
    if ( $internal ) {
      $type_value = 'Internal';
      die 'Ok';
    }

    # Tests for mailing list
    my $is_list = $msginfo->orig_header_fields->{'list-id'};
    $is_list = $is_list || $msginfo->orig_header_fields->{'list-unsubscribe'};
    if ( $is_list ) {
      $type_value = 'List';
      $reason = 'Headers';
      die 'Ok';
    }

    # Bulk emails test
    my $precedence = $msginfo->orig_header_fields->{'precedence'};  # e.g. List
    my $is_bulk = $precedence =~ /^[ \t]*(bulk|list|junk)\b/i ? $1 : undef;

    if ( $is_bulk ) {
      $reason = 'Precedence';
      $type_value = 'Bulk';
      die 'Ok';
    }

    # Check each bulk specific email headers
    foreach ( @bulk_headers ) {
      my $bulk_header = $msginfo->orig_header_fields->{lc $_};
      if ( $bulk_header ) {
        $reason = sprintf 'Bulk header (%s)', $_;
        $type_value = 'Bulk';
        die 'Ok';
      }
    }

    # At this stage, it may be a legitimate private email,
    # or a bulk email...
    # We are going to use several parameters to check for bulk email

    # parameters used to detect bulk email
    my $nb_links = 0;
    my $unsubscribe_link = 0;
    my $fixed_layout = 0;

    # mail body is only stored in file, which may be read if desired
    my $fh = $msginfo->mail_text;  # file handle of our original mail
    my $line;
    my $previous_line;
    my $line_cnt = 0;
    my $unsubscribe_regex = '.*(unsubscribe|opt\s?out|stop\s?receiving).*';
    my $inside_table = 0;

    # start by inspecting the message, line by line
    $fh->seek(0,0) or die "Can't rewind mail file: $!";

    for ($! = 0; defined($line = $fh->getline); $! = 0) {
      $line_cnt++;

      # search for unsubscribe
      if ( $line ~~ /https?:\/\// ) {
        $nb_links++;
        if ( $line ~~ /$unsubscribe_regex/i || $previous_line ~~ /$unsubscribe_regex/i ) {
          $unsubscribe_link = 1;
          $reason = 'Unsubscribe Link';
          last;
        }
      }

      # check for fixed width tables/divs
      elsif ( $line ~~ /style="[^"]*width:[0-9]+px/i ) {
        $fixed_layout = 1;
        $reason = 'Fixed Layout';
        last;
      }

      # check for multiple tables
      elsif ( $line ~~ /<\/table>.*<\/table>/i ) {
        $fixed_layout = 1;
        $reason = 'Tables Layout';
        last;
      }

      # check for imbricated tables
      elsif ( $line ~~ /<table/i ) {
        $inside_table++;

        if ( $inside_table > 1 ) {
          $fixed_layout = 1;
          $reason = 'Nested Tables';
          last;
        }

      }

      # check for multiple tables
      elsif ( $line ~~ /<\/table>/i ) {
        $inside_table--;
      }

      $previous_line = $line;
    }

    if ( $unsubscribe_link || $fixed_layout) {
        $type_value = 'Bulk';
        die 'Ok';
    }

    #  $hdr_edits->prepend_header('X-Message-ID', 'Custom Header');
    #  $hdr_edits->add_header('X-ActualMessageSizeBytes', $mail_size);
    #  $hdr_edits->add_header('X-ActualMessageSize',
    #                         '*' x ($mail_size_mb > 50 ? 50 : $mail_size_mb));

    # clasify as private by default
    $type_value = 'Private';
  };
  if ( $@ && $@ != 'Ok' ) {
    $hdr_edits->add_header('X-Email-Type-Error', $@);
    my $log_level = 2;  # log level (0 is the most important, 1, 2,... 5 less so)
    do_log($log_level,"Error when classifying message: %s", $@);
  }
  else {
    # Finally, add the type header
    $hdr_edits->add_header($type_header, "$type_value");
    $hdr_edits->add_header($type_reason_header, "$reason");
  }

  # Add tests results
  if ( $debug ) {
    my $tests_results = sprintf("ContentType:%s/%d\n", $content_type, $is_text);
    $tests_results   .= sprintf("Domain:%s\n", $domain);
    $tests_results   .= sprintf("Internal:%s\n", $internal);
    $tests_results   .= sprintf("Recipients:%s\n", join(',',@recips));
    $hdr_edits->add_header('X-Email-Type-Debug', $tests_results);
  }


  $self;  # returning an object activates further callbacks,
          # returning undef disables them
}

