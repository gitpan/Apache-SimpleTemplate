package Apache::SimpleTemplate;
#
# a very simple mod_perl template parser.
#
# (c) 2001-2002 peter forty
#
# you may use this and/or distribute this under
# the same terms as perl itself.
#

use Apache ();
use strict;

our $VERSION = 0.02;
our %____cache;


#
# handler
#
# the Apache/mod_perl handler
#

sub handler {

    my $r = shift;

    my $s = shift || new Apache::SimpleTemplate($r);
    unless ($r) { return &cgi_handler($s); }

    my $out = $s->render($ENV{DOCUMENT_ROOT}.$s->{file});

    # send any header stuff from headerref
    foreach my $h (keys %{$s->{headerref}}) { 
	$r->header_out($h, $s->{headerref}->{$h}); 
    }
    # set my status and content_type...
    $r->content_type($s->{content_type});
    $r->status($s->{status});
    $r->send_http_header;

    # send the document if we're OK
    if ($s->{status} == 200) { $r->print($out); }

    return $s->{status};

}

#
# cgi_handler 
# 
# a way to use simpletemplate in CGI mode, 
# called by handler if no Apache object $r given.
#

sub cgi_handler {

    my $s = shift;

    $s->{file} = $_[0] || $s->{inref}->{file} || $s->{file};
    $s->{content_type} = $s->{inref}->{content_type} || $s->{content_type} || 'text/html';

    my $out = $s->render($ENV{DOCUMENT_ROOT}.$s->{file});

    # send any header stuff from headerref
    foreach my $h (keys %{$s->{headerref}}) { 
		print $h . ': ' . $s->{headerref}->{$h} . "\n";
    }
    # set my status and content_type...
    print 'Content-type: '. $s->{content_type} . "\n\n";

    # send the document if we're OK
    if ($s->{status} == 200) { print $out; }
	
    return $s->{status};

}


#########################################################
# OBJECT CREATOR/METHODS
#

#
# new
#
# make a new instance of SimpleTemplate
# given the current Apache request object ($r)
#

sub new {

    my $class = shift;
    my $r = shift;
    my $self = {};

    if (ref($r) =~ m/Apache/) { 
	$self->{file} = $r->dir_config('SimpleTemplateFile') || 
	    ($ENV{SCRIPT_NAME} . $ENV{PATH_INFO});
	$self->{block_begin} = $r->dir_config('SimpleTemplateBlockBegin') || '{{';
	$self->{block_end} = $r->dir_config('SimpleTemplateBlockEnd') || '}}';
	$self->{content_type} = $r->dir_config('SimpleTemplateContentType') || 'text/html';
	$self->{cache} = $r->dir_config('SimpleTemplateCache') || 0;
    }
    
    $self->{r} = $r;
    $self->{inref} = (ref($r) eq 'HASH') ? $r : &parse_form($r);
    $self->{headerref} = {};
    $self->{status} = 200;

    bless($self, $class);

    return $self;

}


#
# render
#
# takes a full path to a template
#

sub render {

    my $s = shift;

    my $inref = $s->{inref};
    my $headerref = $s->{headerref};
    my $content_type = $s->{content_type} || 'text/html';
    my $status = $s->{status};

    my $____o_u_t_;

    unless ($____o_u_t_ = $____cache{$_[0]}) {
	($status, $____o_u_t_) = &load($s->{status}, $_[0]);
	$____cache{$_[0]} = $____o_u_t_ if ($s->{cache} && ($status == 200));
    }

    my $____block_begin = $s->{block_begin} || '{{';
    my $____block_end = $s->{block_end} || '}}';
    $____block_begin =~ s/([^\w])/\\$1/g;
    $____block_end =~ s/([^\w])/\\$1/g;
    #print STDERR "DELIM: $____block_begin $____block_end\n";

    my $out = undef;
    $____o_u_t_ =~ s/$____block_begin(\+?)(.*?)$____block_end/
    {
	my $____encode = $1;
	my $____block = eval($2);
	if ($@) { print STDERR "** Apache::SimpleTemplate $_[0]: $@\n"; }
	
	if (defined $out) { $____block = $out; }
	if ($____encode) { $____block = &encode($____block); }
	
	$out = undef;
	$____block;
    }
    /gse;

    $s->{status} = $status;
    $s->{content_type} = $content_type;

    return $____o_u_t_;

}


#
# include
#
# for use in templates, so they can include other templates/files.
# takes a path relative to the document root. 
#   $s->include('/path/relative/to/docroot.stml');
#
# or statically
#   &Apache::SimpleTemplate::include('/path/relative/to/docroot.stml', $inref);
#   &Apache::SimpleTemplate::include('/path/relative/to/docroot.stml');
#

sub include {

    my $s = shift;

	if (ref $s) {
		return $s->render($ENV{DOCUMENT_ROOT}.$_[0]);
	}

	else {
		my $template = $s;
		my $inref = $_[0];
		unless ($inref) { $inref = &parse_form(); }

		$s = new Apache::SimpleTemplate($inref);
		return $s->render($ENV{DOCUMENT_ROOT}.$template);
	}

}



#########################################################
# OTHER FUNCTIONS 
#


sub encode {

    my $s = shift;
    return undef unless defined($s);

    $s =~ s/([^a-zA-Z0-9_.-])/uc sprintf("%%%02x",ord($1))/eg;

    return $s;

}

sub decode {

    my $s = shift;
    return undef unless defined($s);

    $s =~ s/\%([0-9a-fA-F]{2})/chr(hex($1))/eg;

    return $s;

}


#
# preload a template into memory
# takes a full path
#

sub preload {

    my ($status, $tmp) = &load(200, $_[0]);
    if ($tmp) { $____cache{$_[0]} = $tmp; }

}


#
# parse_form
#
# try to get the form data every which way..
# %form = $r->args; loses multiple checkboxes.... 
#   and doesn't parse a QUERY STRING in a POST. :(
#

sub parse_form {

    my ($r) = @_;

    my (%form, @form);
    if ($r && $r->args) {
	@form = $r->args;
    }
    elsif ($ENV{QUERY_STRING}) {
	foreach my $pair (split('&', $ENV{QUERY_STRING})) { 
	    my ($k, $v) = split('=', $pair);
	    push (@form, &decode($k), &decode($v));
	} 
    }
    if (($r) && ($r->method() eq 'POST') && ($r->header_in('Content-Length') > 0)) {
	push @form, $r->content();
	$r->header_in('Content-Length', 0);
    }

    for (my $i = 0; $i < $#form; $i += 2) {
	## $r->content returns empty things 
	## as undefs instead of as empty strings...
	unless (defined $form[$i+1]) { $form[$i+1] = ''; }

	$form{$form[$i]} = $form{$form[$i]} ? 
	    $form{$form[$i]}."\0".$form[$i+1] : $form[$i+1];
    }

    return \%form;

}


#
# load()
#
# given a full path/filename, 
# return the file as a string.
#

sub load {
  
    my ($status, $filename) = @_;
    my $ret;

    local $/ = undef;

    unless (open FILE, $filename) {
        print STDERR "** Apache::SimpleTemplate: Unable to load $filename: $!\n";
        return ( (($status == 200) ? 404 : $status), '');
    }
    while(<FILE>) { $ret .= $_; }
    
    return ($status, $ret);
    
}

1;

__END__

=head1 NAME

  Apache::SimpleTemplate

=head1 SYNOPSIS

=head2 in httpd.conf:

  <Files *.stml>
    SetHandler perl-script
    PerlHandler +Apache::SimpleTemplate
    ### options:
    #PerlSetVar SimpleTemplateCache 0
    #PerlSetVar SimpleTemplateBlockBegin "{{"
    #PerlSetVar SimpleTemplateBlockEnd "}}"
    #PerlSetVar SimpleTemplateContentType "text/html"
    #PerlSetVar SimpleTemplateFile "/templates/foo.stml"
  </Files>


=head2 in a template:

=head3  {{ _some_perl_code_; }}

     evaluates the perl code, and the block gets replaced by the 
     last value returned in the perl code.

=head3  {{+ _some_perl_code_; }}

     is the same, but the output gets url-encoded.

=head3  {{ $s->include('/some/file'); }}

     includes another file or parsed-template.

=head3  {{ $$inref{foo}; }}

     gives the value of the CGI/form input variable 'foo'.

=head3  {{ $$headerref{Location} = '/'; $status = 302; ''; }}

     redirects to '/'.

=head3  {{ $content_type = 'text/xml'; ''; }}    

     sets the content-type to 'text/xml' instead of the default 'text/html';


=head1 DESCRIPTION

Apache::SimpleTemplate is *another* Template-with-embedded-Perl package
for mod_perl. It allows you to embed blocks of Perl code into text
documents, such as HTML files, and have this code executed upon HTTP
request. It should take moments to set-up and learn; very little knowledge 
of mod_perl is necessary.

This module is meant to be a slim and basic alternative to more fully
featured packages like Apache::Embperl, Apache::ASP, TemplateToolkit.
You may wish to compare approaches and features, and consider trade-offs
in funcionality, implementation time, speed, memory consumption, etc.

Apache::SimpleTemplate has no added syntax/tags/etc, and only the bare 
necessities of functionality. Thus, it should have a very small memory 
footprint and little processing overhead. It has basic caching and
pre-loading options for templates to help you tweak performance. It is 
also designed for making subclasses, in which you can add the functionality 
you want. 

=head1 INSTALLATION

The only requirement is mod_perl. To install Apache::SimpleTemplate, run:

  perl Makefile.PL
  make
  make install

=head1 EXAMPLES

=head2 template "/printenv.stml"

  {{ $s->include('/nav/header.stml'); }}

  <table border=3>
  <tr><th colspan=2>env</th></tr>

  {{
    foreach my $e (sort keys(%ENV)) {
          $out .= "<tr><td><strong>$e</strong></td><td>$ENV{$e}</td></tr>\n";
    }
  }} 

  <tr><th colspan=2>args</th></tr>

  {{
    foreach my $e (sort keys %$inref) {
          $out .= "<tr><td><strong>$e</strong></td><td>$$inref{$e}</td></tr>\n";
    }
  }}

  </table>

=head2 subclass "MyTemplate"

  # in httpd.conf should set the handler: "PerlHandler +MyTemplate"
  # in your template you can call: "{{$s->my_method}}"

  package MyTemplate;
  use Apache::SimpleTemplate ();
  our @ISA = qw(Apache::SimpleTemplate);

  # handler() must be defined, as it is not a method.
  # instantiate this class, and call SimpleTemplate's handler:
  sub handler {
      my $r = shift;
      my $s = new MyTemplate($r);

      # you can do additional steps/calls here, even to change
      # $s->{status} and/or $s->{file} for a different template.

      return Apache::SimpleTemplate::handler($r, $s);
  }
  
  sub my_method {
      my $self = shift;
      return 'this is my_method.';
  }
  1;

=head2 cgi script "simpletemplate.cgi"

  #!/usr/bin/perl
  # 
  # example using SimpleTemplate as a CGI.
  # this *must* be called with a "file" arg or have $s->{file} defined.
  #
  # eg: /simpletemplate.cgi?file=/printenv.stml&content_type=text/html
  #

  # (could use our subclass here instead.)
  use Apache::SimpleTemplate;              
  my $s = new Apache::SimpleTemplate();

  # other stuff can go here.
  # eg, set $s->{file} and $s->{content_type}, call subs, etc...

  #$s->{block_begin} = '{{';
  #$s->{block_end} = '}}';

  exit &Apache::SimpleTemplate::handler(undef);


=head1 VARIABLES & FUNCTIONS

=head2 variables in templates:

  $inref        - a reference to a hash containing the CGI/form input args
  $headerref    - a reference to a hash into which the template can
                  put out-going http headers. (Location, Set-Cookie, etc.)
  $content_type - the template can override this.
  $status       - the template can set this on errors or to redirect.
                  (the rest of the template is still processed.)
  $r            - this instance of 'Apache', i.e. the request object.
  $s            - this instance of 'Apache::SimpleTemplate' (or your subclass)
  $out          - a block of code can use this for the output, instead
                  of the last value returned by the block. 
  $____*        - these names are reserved for use inside the parsing function.

=head2 methods/functions

  $s->include('/some/path')   -- include another document/template.
                                 the path is relative to the document root

  &encode($string)            -- url-encode the $string.
  &decode($string)            -- url-decode the $string.
  &preload($file)             -- preload the template in $file (a full path).
                                 for use in a startup.pl file.

  &Apache::SimpleTemplate::include('/some/path');
                              -- include call for use in other code ouside a template
  &Apache::SimpleTemplate::include('/some/path', $inref);
                              -- same but without reparsing the input fields.

=head2 PerlSetVar options 

  SimpleTemplateBlockBegin    -- the delim for a code block's end ['{{']
  SimpleTemplateBlockEnd      -- the delim for a code block's start ['}}']
  SimpleTemplateCache         -- keep templates in memory? [0]
  SimpleTemplateContentType   -- the default content_type ['text/html']

  SimpleTemplateFile          -- template file location (w/in doc_root)
                                 probably useful only within a <Location>.
                                 [the incoming request path]

=head1 OTHER TIDBITS

=head2 template processing

  Any errors in evaluating a code block should get logged to the error_log.

  Any additional variables you wish to use need to be declared (with 'my').
  If you want to share values between code blocks, the best thing to do
  is to stuff them into $inref or into your (subclass) instance $s.

  Please note that if you are using the default delimiters '{{' & '}}', 
  you should avoid "{{$$inref{foo}}}", which will not work. Write 
  "{{$$inref{foo};}}" or "{{ $$inref{foo} }}" instead.

  A template is always completely parsed, even if $status is changed from 200
  within the template or within a subclass handler. In a subclass handler,
  you can switch to an error template if desired by setting $s->{file}.

  Included sub-templates recieve the same instance of $s, so they have the 
  same $inref, etc. Thus, they can also set headers, change $status, etc.

=head2 performance notes

  If SimpleTemplateCache is on (1) or a template is pre-loaded with preload(),
  Apache must be restarted to see template changes. Otherwise, templates
  are loaded upon each request, and changes appear immediately.

  preload() can be used even with caching off (0), if you have a handful of
  templates you want to cache but many others you do not. preload() may not
  improve speed over caching, but should reduce unshared memory consumption.

  The regular CGI mode will probably be very very slow, so you may want
  only to use it when testing something (a cached template or another
  module/subclass) and you do not want to restart Apache constantly.

  The template parsing herein is very similar to that of Text::Template,
  but even dumber. (Instead of using Text::Template, the template
  parsing was implemented internally for better speed.)

=head1 VERSION

  Version 0.02, 2002-September-02.

=head1 AUTHOR

  peter forty 
  Please send any comments or suggestions to
  mailto:apache-simple-template@peter.nyc.ny.us

  The homepage for this project is: 
  http://peter.nyc.ny.us/simpletemplate/

=head1 COPYRIGHT (c) 2001-2002

  This is free software with absolutely no warranty.
  You may use it, distribute it, and/or modify 
  it under the same terms as Perl itself.

=head1 SEE ALSO

L<perl>, L<mod_perl>.

=cut
