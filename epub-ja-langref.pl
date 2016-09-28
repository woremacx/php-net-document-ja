#!/usr/bin/env perl
use strict;
use warnings;
use Web::Scraper;
use LWP::UserAgent;
use URI;
use Path::Class;
use EBook::EPUB;
use Text::Xslate;
use Cache::File;
use Storable qw(nfreeze thaw);

my $workdir = 'work';
my $top = 'http://php.net/manual/ja/langref.php';

my $template = << 'TMPL;';
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
  <title>[% title %]</title>
</head>
<body>
[% content | mark_raw %]
</body>
</html>
TMPL;

my $xslate = Text::Xslate->new(
    syntax => 'TTerse',
    module => [
        'Text::Xslate::Bridge::TT2Like'
    ],
);

my $epub = EBook::EPUB->new;

my $nav = 1;

my $s_title = scraper {
    process '//h1', h1 => 'TEXT';
    process '//h2', h2 => 'TEXT';
    process '//h3', h3 => 'TEXT';
    process '.title', title => 'TEXT';
};

sub save {
    my ($uri, $content) = @_;
    my $href = ($uri->path_segments)[-1];

    my $res = $s_title->scrape($content);
    my $title = "no-title";
    for my $key (qw/title h1 h2 h3/) {
        if (defined($res->{$key})) {
            $title = $res->{$key};
            last;
        }
    }

    my $stash = {
        title   => $title,
        content => $content,
    };

    my $result = $xslate->render_string($template, $stash);

    my $d = dir($workdir);
    my $file = $d->file($href);
    my $fh = $file->openw;
    binmode $fh, ":utf8";
    print $fh $result;
    $fh->close;

    my $id = $epub->copy_xhtml($file, $href);

    my $navpoint = $epub->add_navpoint(
        label      => $title,
        id         => $id,
        content    => $href,
        play_order => $nav++,
    );
}

sub process_page {
    my $uri = shift;

    my $base = ($uri->path_segments)[-1];
    $base =~ s/\.php$//;

    my $name = sprintf('//div[@id="%s"]', $base);

    my $s_page = scraper {
        process $name, content => 'HTML';
    };

    my $res = $s_page->scrape(fetch($uri));
    save($uri, $res->{content});
}

my $ua = LWP::UserAgent->new;
my $cache_root = dir("cache")->absolute;
my $cache = Cache::File->new( cache_root => $cache_root, default_expires => '7 day' );

sub fetch {
    my $uri = shift;
    my $key = $uri->as_string;
    if (my $cached = $cache->get( $key )) {
        #warn "cached $key";
        return thaw($cached);
    }
    my $res = $ua->get( $key );
    $cache->set( $key, nfreeze($res) );
    sleep(1);
    return $res;
}

my $s_index = scraper {
    process '//div[@id="langref"]', content => 'HTML';
    process 'div.book a', 'links[]', '@href';
    process 'h1.title', title => 'TEXT';
};

sub main {
    my $topuri = URI->new($top);
    my $res = $s_index->scrape(fetch($topuri));

    $epub->add_title($res->{title});
    $epub->add_language('ja');

    dir($workdir)->mkpath;

    save($topuri, $res->{content});

    for my $uri (@{ $res->{links} }) {
        process_page($uri);
    }

    my $filename = "output.epub";
    $epub->pack_zip($filename);
}

main;
