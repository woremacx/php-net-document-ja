#!/usr/bin/env perl
use strict;
use warnings;
use Web::Scraper::LibXML;
use LWP::UserAgent;
use URI;
use Path::Class;
use EBook::EPUB;
use Text::Xslate;
use Cache::File;
use Storable qw(nfreeze thaw);

my $workdir = 'work';
my $top = 'http://php.net/manual/ja/funcref.php';
my $filename = "funcref.epub";
my $domain = URI->new($top)->host;

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

sub scrape_page {
    my ($uri, $level1only) = @_;

    my $base = ($uri->path_segments)[-1];
    $base =~ s/\.php$//;

    my $name = sprintf('//div[@id="%s"]', $base);
    my $name_a = sprintf('//div[@id="%s"]/ul/li/a', $base);

    my $s_page = scraper {
        process $name, content => 'HTML';
        process $name_a, 'links[]', '@href';
        process '//h1', h1 => 'TEXT';
        process '//h2', h2 => 'TEXT';
        process '//h3', h3 => 'TEXT';
        process '.title', title => 'TEXT';
    };

    my $res = $s_page->scrape(fetch($uri));
    my @links;
    for my $link (@{ $res->{links} }) {
        next unless ref($link);
        next unless $link->host eq $domain;
        push(@links, $link);
    }
    $res->{links} = \@links;
    $res;
}

my $ua = LWP::UserAgent->new;
my $cache_root = dir("cache")->absolute;
my $cache = Cache::File->new( cache_root => $cache_root, default_expires => '7 day' );

sub fetch {
    my $uri = shift;
    my $key = $uri->as_string;
    if (my $cached = $cache->get( $key )) {
        warn "[cache hit] $key";
        return thaw($cached);
    }
    warn "[cache miss] $key";
    my $res = $ua->get( $key );
    $cache->set( $key, nfreeze($res) );
    sleep(1);
    return $res;
}

my %seen;
sub process_subpage {
    my $uri = shift;

    my $res = scrape_page($uri);
    save($uri, $res->{content});

    for my $uri (@{ $res->{links} }) {
        next if $uri =~ m!/extensions.php!;
        next if $uri =~ m!objaggregation!;
        next if $seen{$uri}++;
        process_subpage($uri);
    }
}

sub main {
    my $topuri = URI->new($top);
    my $res = scrape_page($topuri, 1);

    $epub->add_title($res->{title});
    $epub->add_language('ja');

    dir($workdir)->mkpath;

    save($topuri, $res->{content});

    for my $uri (@{ $res->{links} }) {
        next if $uri =~ m!/extensions.php!;
        process_subpage($uri);
    }

    $epub->pack_zip($filename);
}

main;
