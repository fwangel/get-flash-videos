# Part of get-flash-videos. See get_flash_videos for copyright.
# Handles streams from the new svtplay.se (launched June 4, 2012)
package FlashVideo::Site::Svtplay;
use strict;
use warnings;
use HTML::Entities;
use FlashVideo::Utils;
use FlashVideo::JSON;

my $encode_rates = {
     "ultralow" => 320,
     "low" => 850,
     "medium" => 1400, 
     "high" => 2400 };

sub find_video {
  my ($self, $browser, $embed_url, $prefs) = @_;
  $self->identify_and_fetch($browser, $embed_url, $prefs);
}

sub identify_and_fetch {
    my ($self, $browser, $embed_url, $prefs) = @_;
    my $title = ($browser->content =~ /data-title="([^"]*?)"/)[0];
    my $info_url = ($browser->content =~ /data-popout-href="([^"]*?)"/)[0];

    if ($info_url) {
      $self->fetch_new_style($browser, $embed_url, $prefs, $title, $info_url);
    } else {
      $self->fetch_old_style($browser, $embed_url, $prefs);
    }
}

sub fetch_new_style {
  my ($self, $browser, $embed_url, $prefs, $title, $info_url) = @_;

  debug "Using new-style SVTPlay to download \"$title\"";

  my $program_description = ($browser->content =~ /<div.*?class.*?playVideoInfo.*?>.*?<\/h5>.*?<span>(.*?)<\/span>/s)[0];
  if ($program_description) {
    $program_description = decode_entities($program_description);
    $program_description =~ s/^\s+|\s+$//g;
    $program_description .= "\n\n";
  } else {
    $program_description = "";
  }

  my $episode_description = ($browser->content =~ /<div.*?class.*?playVideoInfo.*?>.*?<p.*?class.*?svtXMargin-Top-S.*?>(.*?)<\/p>/s)[0];
  if ($episode_description) {
    $episode_description = decode_entities($episode_description);
    $episode_description =~ s/^\s+|\s+$//g;
  } else {
    $episode_description = "";
  }

  my $description = $program_description . $episode_description;
  if ($description) {
    my $txt_filename = title_to_filename($title, "txt"); 
    info "Saving episode description to \"$txt_filename\"";
    open(TXT, '>', $txt_filename)
      or die "Can't open description file \"$txt_filename\": $!";
    binmode TXT, ':utf8';
    print TXT $description;
    close TXT;
  }

  debug "Fetching \"$info_url\" for more details..";
  $browser->get($info_url);
  if (!$browser->success) {
    die "Failed to fetch details from \"$info_url\": " . $browser->response->status_line;
  }

  my $base_url = ($embed_url =~ /(http:\/\/.*?)\//)[0];
  my $object = ($browser->content =~ /(<object.*?class.*?"svtplayer.*?<\/object>)/s)[0];
  my $swfVfy = ($object =~ /<param.*?"movie".*?value.*?"(\/.*?.swf)"/s)[0];
  my $flashvars = ($object =~ /<param.*?"flashvars".*?value="json=({.*?})"/s)[0];
  my $json = from_json(decode_entities($flashvars));

  my $flv_filename = title_to_filename($title, "flv");
  my $preferred_bitrate = $encode_rates->{$prefs->{quality}};

  # find the url with the highest bitrate at or below preferences
  my $best_url = $json->{video}->{videoReferences}[0]->{url};
  my $best_bitrate = 0;
  my $videoReference;
  foreach $videoReference (@{$json->{video}->{videoReferences}}) {
      # look for proper flash (mp4) videos, skip ios (m3u8) playlists
      if (($videoReference->{playerType} =~ /flash/)[0]) {
        my $bitrate = int($videoReference->{bitrate});
        if ($bitrate <= $preferred_bitrate && $bitrate > $best_bitrate) {
          $best_url = $videoReference->{url};
          $best_bitrate = $bitrate;
        }
     }
  }

  my $subtitles = $json->{video}->{subtitleReferences}[0]->{url};
  if ($subtitles) {
    info "Fetching subtitles from \"$subtitles\"...";
    $browser->get("$subtitles");
    my $srt_filename = title_to_filename($title, "srt"); 
    my $srt_content = $browser->content;
    open(SRT, '>>', $srt_filename)
      or die "Can't open subtitles file \"$srt_filename\": $!";
    binmode SRT, ':utf8';
    print SRT $srt_content;
    close SRT;
  } else {
    info "No subtitles found!";
  }

  my $args = {
    rtmp => "$best_url",
    flv => "$flv_filename",
  };
  if ($swfVfy) {
    $swfVfy = "${base_url}${swfVfy}";
    info "Verifying against $swfVfy";
    $args->{swfVfy} = $swfVfy;
  }

  return $args;
}

sub fetch_old_style {
  my ($self, $browser, $embed_url, $prefs) = @_;

  debug "Using old-style SVTPlay";

  my @rtmpdump_commands;
  my $url;
  my $low;
  my $ultralow;
  my $medium;
  my $high;
  my $data = ($browser->content =~ /dynamicStreams=(.*?)&/)[0];
  my @values = split(/\|/, $data); 
  foreach my $val (@values) {
    if (($val =~ m/url:(.*?),bitrate:2400/)){
       $high = ($val =~ /url:(.*?),bitrate:2400/)[0];
       debug "Found " . "$high";
    } elsif (($val =~ m/url:(.*?),bitrate:1400/)){
       $medium = ($val =~ /url:(.*?),bitrate:1400/)[0];
       debug "Found " . "$medium";
    }elsif (($val =~ m/url:(.*?),bitrate:850/)){
       $low = ($val =~ /url:(.*?),bitrate:850/)[0];
       debug "Found " . "$low";
    }elsif(($val =~ m/url:(.*?),bitrate:320/)){
       $ultralow = ($val =~ /url:(.*?),bitrate:320/)[0];
       debug "Found " . "$ultralow";
    }
  }

  my $encode_rate = $encode_rates->{$prefs->{quality}};
  if ($encode_rate == 2400 && defined $high) {
    $url = $high;
  } elsif ($encode_rate == 1400 && defined $medium) {
    $url = $medium;
  } elsif ($encode_rate == 850 && defined $low) {
    $url = $low;
  } elsif ($encode_rate == 320 && defined $ultralow) {
    $url = $ultralow;
  } elsif (defined $high){
    $url = $high;
    debug "Using high"
  } elsif (defined $medium) {
    $url = $medium;
    debug "Using medium"
  } elsif (defined $low) {
    $url = $low;
    debug "Using low"
  } elsif (defined $ultralow) {
    $url = $ultralow;
    debug "Using ultralow"
  }
  
  info "Using rtmp-url: $url";
  my $sub = ($browser->content =~ /subtitle=(.*?)&/)[0];
  my $videoid = ($browser->content =~ /videoId:'(.*?)'}/)[0];
  debug "videoid:$videoid";
  my $swfVfy = ($browser->content =~ /"(\/.*?.swf)"/)[0];
  debug "swfVfy:$swfVfy";
  $browser->get("http://svtplay.se/popup/lasmer/v/" . "$videoid");
  my $title = ($browser->content =~ /property="og:title" content="(.*?)" \/>/)[0];
  my $flv_filename = title_to_filename($title, "flv");

  if ($prefs->{subtitles} == 1) {
    if ($sub) {
      info "Found subtitles: $sub";
      $browser->get("$sub");
      my $srt_filename = title_to_filename($title, "srt"); 
      my $srt_content = $browser->content;
      open (SRT, '>>',$srt_filename) 
        or die "Can't open subtitles file $srt_filename: $!";
      binmode SRT, ':utf8';
      print SRT $srt_content;
      close SRT;
    } else {
      info "No subtitles found!";
    }
  }
  my $args = {
    rtmp => "$url",
    flv => "$flv_filename",
  };
  if ($swfVfy) {
    $swfVfy = "http://svtplay.se$swfVfy";
    info "Verifying against $swfVfy";
    $args->{swfVfy} = $swfVfy;
  }
  push @rtmpdump_commands, $args;
  return \@rtmpdump_commands;
}

1;
