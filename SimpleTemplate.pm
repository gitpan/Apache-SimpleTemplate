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

our $VERSION = 0.03;
our %_cache;
our %_cache_time;


#
# handler
#
# the Apache/mod_perl handler
#

sub handler {

    my $r = shift;

    my $s = shift || new Apache::SimpleTemplate($r);
    #unless ($r) { return &cgi_handler($s); }

	print STDERR "-------- Apache::SimpleTemplate::handler REQUEST FOR $s->{file}\n" if $s->{debug};

    my $out = ($s->{status} == 200) ? $s->render($ENV{DOCUMENT_ROOT}.$s->{file}) : '';

    # send any header stuff from headerref
    foreach my $h (keys %{$s->{headerref}}) {
		if ($r) {
			my $cur = $r->header_out($h);
			if ($cur) { $r->header_out($h, ($cur . "\n" . $h . ': ' . $s->{headerref}->{$h})); }
			else      { $r->header_out($h, $s->{headerref}->{$h});	}
		}
		else {
			print $h . ': ' . $s->{headerref}->{$h} . "\n";
		}
    }

	print STDERR "-------- Apache::SimpleTemplate::handler STATUS $s->{status}\n" if $s->{debug};
	print STDERR "-------- Apache::SimpleTemplate::handler CTYPE  $s->{content_type}\n" if $s->{debug};

	unless ($r) {
		print 'Content-type: '. $s->{content_type} . "\n\n";
		if ($s->{status} == 200) { print $out; }
		else { print ($s->{_error}); }
		return ($s->{debug} && $s->{_error}) ? undef : $s->{status};
	}

    # set my status and content_type...
    $r->status($s->{status});
    $r->content_type($s->{content_type});
    $r->send_http_header;

    # send the document if we're OK
    if ($s->{status} == 200) { $r->print($out); }
	else { $r->print($s->{_error}); }

	return ($s->{debug} && $s->{_error}) ? undef : $s->{status};

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
		$self->{file} = $r->dir_config('SimpleTemplateFile');
		$self->{block_begin} = $r->dir_config('SimpleTemplateBlockBegin');
		$self->{block_end} = $r->dir_config('SimpleTemplateBlockEnd');
		$self->{content_type} = $r->dir_config('SimpleTemplateContentType');

		$self->{cache} = $r->dir_config('SimpleTemplateCache');
		$self->{reload} = $r->dir_config('SimpleTemplateReload');
		$self->{debug} = $r->dir_config('SimpleTemplateDebug') || 0;
    }
	if (!defined $self->{cache}) { $self->{cache} = 1; }
	if (!defined $self->{reload}) { $self->{reload} = 1; }
	if (!defined $self->{block_begin}) { $self->{block_begin} = '{{'; }
	if (!defined $self->{block_end}) { $self->{block_end} = '}}'; }
	if (!defined $self->{file}) { $self->{file} = ($ENV{SCRIPT_NAME} . $ENV{PATH_INFO}); }
	if (!defined $self->{content_type}) { $self->{content_type} = 'text/html'; }

	print STDERR "-- NEW SimpleTemplate OBJECT FOR $self->{file}\n" if $self->{debug} > 1;
    
    $self->{r} = $r;
    $self->{inref} = (ref($r) eq 'HASH') ? $r : &parse_form($r);
    $self->{headerref} = {};
    $self->{status} = 200;

    bless($self, $class);

    return $self;

}


# getters/setters
sub status { my $s = shift; return $_[0] ? $s->{status} = $_[0] : $s->{status}; }
sub content_type { my $s = shift; return $_[0] ? $s->{content_type} = $_[0] : $s->{content_type}; }
sub file { my $s = shift; return $_[0] ? $s->{file} = $_[0] : $s->{file}; }


#
# header
# 
# safely add a header (without squashing an existing entry.)
#
sub header {
	my ($s, $name, $value) = @_;
	my $cur = $s->{headerref}->{$name};
	if ($cur) { $s->{headerref}->{$name} = $cur . "\n" . $name . ': ' . $value; }
	else      { $s->{headerref}->{$name} = $value; }
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

	my $package = 'Apache::SimpleTemplate::Template'.$_[0];
	$package =~ s/\//\:\:/g;
	$package =~ s/[^\w\:]/_/g;
	print STDERR "-- RENDERING ($package)\n" if $s->{debug};

	my $fun = $_cache{$_[0]};
	my $usecache = $fun ? 1 : $s->{cache};

	# check for updated template
	if ($fun && $s->{reload}) {
		my $filetime = (stat($_[0]))[9];
		if ($_cache_time{$_[0]} < $filetime) {
			print STDERR "-- RELOADING ($package)\n" if $s->{debug};
			$fun = undef;
		}
	}

	# check for cache
    if ($fun) {
		print STDERR "-- CACHE HIT ($package)\n" if $s->{debug};
	} 
	else {
		print STDERR "-- COMPILING ($package)\n" if $s->{debug};

		$fun = $s->compile($_[0]);
		if ($fun && $usecache)  { 
			if ($s->{reload}) { $_cache_time{$_[0]} = time; }
			$_cache{$_[0]} = $fun; 
		}
	}

	#print STDERR "-- SETTING STATUS for $s to $s->{status}\n" if $s->{debug};
	if (!(ref $fun)) {
		if ($fun != 200) { $s->{status} = $fun; return ''; }
		my $packagefun = $package.'::____g_o_';
		$fun = \&$packagefun;
	}

	return &$fun($s);

}

#
# compile a template
#
# load from file:
#   $s->compile('/www/myhost.com/foo.stml');
# pass in body:
#   $s->compile($template, 1);
#

sub compile {

	my $s = shift;

	my $template = $_[1] ? $_[0] : &load($_[0]);
	if (!defined $template) { $s->{_error} .= "Not Found: $_[0]\n"; return 404; }
	
	my $block_begin = $s->{block_begin} || '{{';
	my $block_end = $s->{block_end} || '}}';
	print STDERR "-- DELIM: $block_begin $block_end\n" if $s->{debug} > 1;

	$block_begin =~ s/([^\w])/\\$1/g;
	$block_end =~ s/([^\w])/\\$1/g;
	
	my $eval = '';
	my $precode = '';
	
	my $package = 'Apache::SimpleTemplate::Template'.$_[0];
	$package =~ s/\//\:\:/g;
	$package =~ s/[^\w\:]/_/g;
	my $usepackage = 0;

	$template =~ s/($block_begin)\#(.*?)\#($block_end)/$1.'-'.&blank_lines($2).$3/gse;
	#$template =~ s/$block_begin\-(.*?)$block_end/&blank_lines($1)/gse;
	
	if ($template =~ s/$block_begin\!(.*?)$block_end/
		$precode .= $1 . '; ';
		'';
		/gse) {
		$usepackage = 1;
		if ($s->{debug} > 2) {
			print STDERR "============================INITIAL BLOCK\n";
			print STDERR $precode . "\n";
			print STDERR "============================/INITIAL BLOCK\n";
		}
	}
	
	if ($usepackage) {
		$eval .= "package $package; use Apache::SimpleTemplate; " . $precode; 
	}
	
	$eval .= 'sub ' . ($usepackage?'____g_o_ ':''). '{ my $____out = \'\'; ';
	$eval .= 'my ($s) = @_; my $inref=$s->{inref}; my $headerref=$s->{headerref}; my $status; my $content_type; ';
	
	my @pieces = split (/$block_end/, $template);

	# fix parsing problem if code block at very end of template.
	if (($template =~ m/$block_end$/s) && !($template =~ m/$block_end\n$/s)) { push (@pieces, ''); }

#	for (my $i=0; $i<=$#pieces; $i++) {
#		print STDERR "==================================PIECE $i:\n";
#		print STDERR $pieces[$i];
#		print STDERR "\n==================================\n";
#	}

	my $i = 0;
	for (; $i<$#pieces; $i++) {

		if ($pieces[$i] =~ 
			m/(.*?)$block_begin([\^\+\\\-\=\:]?)(.*?)\;?(\s*)$/gs) {
			my $text = &quote_escape($1);
			my $encode = $2;
			my $block = $3.$4;

			if ($s->{debug} > 2) {
				print STDERR "==================================TEXT $i:\n";
				print STDERR "$1\n";
				print STDERR "==================================CODE ($encode) $i:\n";
				print STDERR "$block\n";
			}

			$eval .= '$____out.=\''.$text."'; ";
			
			if (!$encode) {
				$eval .= $block .'; ';
			}
			elsif ($encode eq ':') {
				$eval .= '{ my $out = undef; my $____tmp=eval {'.$block.'}; ';
				$eval .= '$____out .= (defined $out) ? $out : $____tmp;'.'}; ';
			}
			elsif ($encode eq '=') {
				$eval .= '$____out .= ('.$block.'); ';
			}
			elsif ($encode eq '+') {
				$eval .= '$____out .= &Apache::SimpleTemplate::encode('.$block.'); ';
			}
			elsif ($encode eq '^') {
				$eval .= '$____out .= &Apache::SimpleTemplate::escape('.$block.'); ';
			}
			elsif ($encode eq '\\') {
				$eval .= '$____out .= &Apache::SimpleTemplate::quote_escape('.$block.'); ';
			}
			elsif ($encode eq '-') {
				$eval .= &blank_lines($block);
			}

		}

		else {
			print STDERR "** Apache::SimpleTemplate $_[0]: invalid block in:\n";
			print STDERR $pieces[$i].$s->{block_end}."\n";
			$s->{_error} .= "invalid block: ".$pieces[$i].$s->{block_end}."\n";
			return 500;
		}
		
	}
	
	if ($s->{debug} > 2) {
		print STDERR "==================================TEXT $i:\n";
		print STDERR "$pieces[$i]\n";
		print STDERR "==================================\n";
	}

	$eval .= '$____out.=\''.&quote_escape($pieces[$i]).'\'; ';
	$eval .= 'if ($status) { $s->{status} = $status; }; ';
	$eval .= 'if ($content_type) { $s->{content_type} = $content_type; }; ';
	$eval .= "return (\$____out);\n}";
	
	#if ($usepackage) { $eval .= "1;\n"; }

	if ($s->{debug} > 1) {
		print STDERR "===================================================EVAL\n";
		print STDERR "$eval\n";
		print STDERR "===================================================/EVAL\n";
	}
	
	my $fun = eval($eval);
	if ($@) { print STDERR "** Apache::SimpleTemplate $_[0]: $@\n"; $s->{_error} .= $@; return 500; }

	if ($usepackage) { return 200; }
	return $fun;

}

sub blank_lines {
    my ($string) = @_;
    $string =~ s/[^\n]//g;
	return $string;
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
		print STDERR "---- Apache::SimpleTemplate::include FROM $s->{file} FOR $_[0]\n" if $s->{debug};
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



#
# preload a template into memory
# takes a full path
#

sub preload {

	my $s = shift;

	$_cache{$_[0]} = $s->compile($_[0]);

}



#########################################################
# OTHER FUNCTIONS  (callable as methods, too.)
#


# url-encode a string
sub encode {

    my $s = shift;
	if (ref $s) { $s = shift; }
    return undef unless defined($s);

    $s =~ s/([^a-zA-Z0-9_\.\-\ ])/uc sprintf("%%%02x",ord($1))/eg;
    $s =~ s/\ /\+/g;

    return $s;

}

# url-decode a string
sub decode {

    my $s = shift;
	if (ref $s) { $s = shift; }
    return undef unless defined($s);

	$s =~ s/\+/ /g;
    $s =~ s/\%([0-9a-fA-F]{2})/chr(hex($1))/eg;

    return $s;

}

# html-escape a string ("<tag>" becomes "&lt;tag&gt;")
sub escape {

    my $s = shift;
	if (ref $s) { $s = shift; }
    return undef unless defined($s);

    $s =~ s/\</&lt;/g;
    $s =~ s/\>/&gt;/g;

    return $s;
}

# escape single quotes (') and backslashes (\) with \' and \\
sub quote_escape {

    my $s = shift;
	if (ref $s) { $s = shift; }
    return undef unless defined($s);

	$s =~ s/([\'\\])/\\$1/gs;

	return $s;
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
  
    my ($filename) = @_;
    my $ret;

    local $/ = undef;

    unless (open FILE, $filename) {
        print STDERR "** Apache::SimpleTemplate: Unable to load $filename: $!\n";
		return undef;
    }
    while(<FILE>) { $ret .= $_; }
    
    return ($ret);
    
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
    #PerlSetVar SimpleTemplateCache 1
    #PerlSetVar SimpleTemplateReload 1
    #PerlSetVar SimpleTemplateDebug 0
    #PerlSetVar SimpleTemplateBlockBegin "{{"
    #PerlSetVar SimpleTemplateBlockEnd "}}"
    #PerlSetVar SimpleTemplateContentType "text/html"
  </Files>

  <Location /example>
    SetHandler perl-script
    PerlHandler +Apache::SimpleTemplate
    PerlSetVar SimpleTemplateFile "/templates/example.stml"
  </Location>


=head2 in a template:

=head3  {{! _perl_definitions_or_declarations_ }}

     compiles the code once. (the code block is replaced by nothing.)
     can be used for defining subroutines, 'use' calls, declaring and 
     populating variables/hashes/etc.

=head3  {{ _perl_code_ }}

     executes the perl code. (this block is replaced by nothing.)
     can also declare variables for use within the template.

=head3  {{= _a_perl_expression_ }}

     evaluates the perl expression, and the block gets replaced by 
     the expression's value.

     '{{+ }}' is the same as '{{= }}', but the output gets url-encoded.
     (mnemonic: '+' is a space in a url-encoded string.)

     '{{^ }}'is the same as '{{= }}', but the output gets html-escaped.
     (mnemonic: '^' looks like the '<' and '>' that get replaced.)

     '{{\ }}'is the same as '{{= }}', except single-quotes get escaped.
     (useful for javascript. "'" becomes "\'" and "\" becomes "\\".)

=head3  {{- _a_comment_ }}

     is ignored and replace by nothing.
     (mnemonic: "-" as in "<!-- html comments -->".)

=head3  {{# _comment_out_text_and/or_template_blocks_ #}}

     comment out larger areas of templates, including code blocks.
     NB: the '#' on the closing tag, as this is the only tag which can 
     wrap other tags.

=head3  {{= $s->include('/dir/file.stml') }}

     includes another file or parsed-template.

=head3  {{= $$inref{foo}; }}

     prints the value of the CGI/form input variable 'foo'.

=head3  {{ $s->header('Location','/'); $s->status(302); return; }}

     ends execution of the template and redirects browser to '/'.

=head3  {{ $s->content_type('text/xml'); }}

     sets our content-type to 'text/xml' instead of default 'text/html';

=head3  {{: _perl_code_ }}

     evaluates the perl code, and the block gets replaced by the last
     value returned in the perl code, or $out if defined. (included
     mostly for backward compatability-- it's better to use a mixture
     of {{ }} and {{= }} blocks.)
     (mnemonic: '{{: }}' is like a combination of '{{ }}' and '{{= }}'.)



=head1 DESCRIPTION

Apache::SimpleTemplate is *another* Template-with-embedded-Perl package
for mod_perl. It allows you to embed blocks of Perl code into text
documents, such as HTML files, and have this code executed upon HTTP
request. It should take moments to set-up and learn; very little knowledge 
of mod_perl is necessary, though some knowledge of Apache and perl is
assumed.

This module is meant to be a slim and basic alternative to more fully
featured packages like Apache::Embperl, Apache::ASP, or TemplateToolkit,
and more of a mod_perl counterpart to JSP or PHP. You may wish to compare 
approaches and features of the other perl templating schemes, and consider 
trade-offs in funcionality, implementation time, speed, memory 
consumption, etc. This module's relative lack of "features" is meant to 
improve both its performance and its flexibility.

Apache::SimpleTemplate has no added programming syntax, relying simply
on perl itself for all programming logic in the templates. It should 
run with a very small memory footprint and little processing over-head. 
Templates get compiled into perl packages (or subroutines), and the 
caching and preloading options can help you increace speed and reduce 
memory consumption. SimpleTemplate is also designed for extension
through subclasses, into which you can add the functionality you want. 



=head1 INSTALLATION

The only requirement is mod_perl. To install Apache::SimpleTemplate, run:

  perl Makefile.PL
  make
  make install

Then, to test it with Apache/mod_perl:

  1) put the httpd.conf lines above into your httpd.conf
  2) restart apache
  3) try putting an example template from below into your document root
  4) point your browser at the example



=head1 EXAMPLES

=head2 template "example.stml"


    {{!
        my $foo = 'working!';
        sub not_installed_properly { return $foo;} 
    }}
    <html>
    <body bgcolor="ffffff">

    <h2>Apache::SimpleTemplate seems to be {{= &not_installed_properly(); }} </h2>

    </body>
    </html>


=head2 template "/printenv.stml"

    <table border=3>
        <tr><th colspan=2 align=left>Environment variables</th></tr>

        {{  foreach my $e (sort keys(%ENV)) {   }}
              <tr>
                <td><strong>{{=$e}}</strong></td>
                <td>{{=$ENV{$e};}}</td>
              </tr>
        {{  }  }}
    </table>

    <table border=3>
        <tr><th colspan=2 align=left>CGI Arguments</th></tr>

        {{  foreach my $e (sort keys %$inref) {  }}
              <tr>
                <td><strong>{{=$e}}</strong></td>
                <td>{{=$$inref{$e};}}</td>
              </tr>
        {{  }  }}
    </table>


=head2 subclass "MySimpleTemplate"

  # in httpd.conf should set the handler: "PerlHandler +MySimpleTemplate"
  # in your template you can call: "{{= $s->my_method }}"

  package MySimpleTemplate;
  use Apache::SimpleTemplate ();
  our @ISA = qw(Apache::SimpleTemplate);

  # handler() must be defined, as it is not a method.
  # instantiate this class, and call SimpleTemplate's handler:
  sub handler {
      my $r = shift;
      my $s = new MySimpleTemplate($r);

      # you can make additional steps/logic here, including:
      #     set $s->file() for a template to use
      #     change $s->status()
      #     add headers w/ $s->header()

      return Apache::SimpleTemplate::handler($r, $s);
  }
  
  sub my_method {
      my $self = shift;
      return 'this is my_method.';
  }
  1;


=head2 Use in a CGI script or other code

  #!/usr/bin/perl
  # 
  # example using SimpleTemplate in other code
  #

  # (could use your subclass here instead.)
  use Apache::SimpleTemplate;              
  my $s = new Apache::SimpleTemplate();

  #### options: (caching won't do anything usefule in CGI mode.)
  #$s->{block_begin} = '{{';
  #$s->{block_end} = '}}';
  #$s->{debug} = 0;
  $s->{cache} = 0;
  $s->{reload} = 0;

  #### call as a CGI (will get headers and status set):
  #$s->content_type('text/html');
  $s->file('/dir/file.stml');
  exit &Apache::SimpleTemplate::handler();

  #### or non-CGI use, just get the rendered page:
  # print $s->render('/full/path/to/file.stml');
  

=head1 VARIABLES & FUNCTIONS

=head2 variables in templates:

  $r            - this instance of 'Apache', i.e. the request object.
  $s            - this instance of 'Apache::SimpleTemplate' (or your subclass)
  $inref        - a reference to a hash containing the CGI/form input args
  $out          - a {{: }} block of code can use this for the output, 
                  instead of the last value returned by the block. 
  $____*        - these names are reserved for use inside the parsing function.


=head2 methods/functions in templates:

  $s->content_type('text/xml')   -- set our content-type to something
  $s->header($name,$value)       -- add an outgoing header. (can add multiple 
                                    of the same name.)
  $s->status(302)                -- set our status to something other than 200
  return                         -- stop running this template (within {{ }})

  $s->encode($string)            -- url-encode the $string.
                                    &Apache::SimpleTemplate::encode($string)
  $s->decode($string)            -- url-decode the $string.
                                    &Apache::SimpleTemplate::decode($string)
  $s->escape($string)            -- html-escape the $string.
                                    &Apache::SimpleTemplate::escape($string)
  $s->quote_escape($string)      -- single-quote-escape the $string.
                                    &Apache::SimpleTemplate::quote_escape($string)

  $s->preload($file)             -- preload the template in $file, a full
                                    path which must match the DOCUMENT_ROOT.
                                    (for use in a startup.pl file.)

  $s->include('/dir/file')       -- include another document/template.
                                    the path is relative to the DOCUMENT_ROOT

  &Apache::SimpleTemplate::include('/dir/file');
                              -- include call for outside a SimpleTemplate
  &Apache::SimpleTemplate::include('/dir/file', $inref);
                              -- same without reparsing the CGI input fields


=head2 deprecated vars, use the methods above instead:

  $headerref    - a reference to a hash into which the template can
                  put out-going http headers. (Location, Set-Cookie, etc.)
  $status       - the template can set this on errors or to redirect.
                  (the rest of the template is still processed.)
  $content_type - the template can override this.




=head2 PerlSetVar options 

  SimpleTemplateBlockBegin    -- the delim for a code block's end ['{{']
  SimpleTemplateBlockEnd      -- the delim for a code block's start ['}}']

  SimpleTemplateCache         -- keep templates in memory? [1]
  SimpleTemplateReload        -- check templates for changes? [1]
  SimpleTemplateDebug         -- level of debug msgs in error_log (0-3) [0]
                                 (if >= 1, compile errors go to the browser.)

  SimpleTemplateContentType   -- the default content_type ['text/html']
  SimpleTemplateFile          -- template file location (w/in doc_root)
                                 probably useful only within a <Location>.
                                 [the incoming request path]


=head1 OTHER TIDBITS

=head2 template processing

  Please note that if you are using the default delimiters '{{' & '}}', 
  you should avoid things like "{{$$inref{foo}}}" with 3 '}'s in a row.
  This will not work, so you need to write "{{$$inref{foo};}}" or 
  "{{ $$inref{foo} }}" instead.

  Or, if you're particularly fond of ASP/JSP-style tags, set 
  SimpleTemplateBlockBegin to '<%' and SimpleTemplateBlockEnd to '%>'.
  Then you can use <% %>, <%! %>, <%= %>, <%-- --%> in much the same way
  as in JSP (plus <%+ %>, <%^ %>, and <%\ %> for encoding / escaping).
  This also helps avoid the problem of multiple {s and }s in your code.

  Any errors in evaluating a code block should get logged to the error_log.
  The compilation process tries to keep the line numbers consistent with
  the template, but {{! }} declarations/definitions that are not at the
  top of the template may throw line numbers 

  Any additional variables you wish to use must be declared (with 'my').
  If you declare them in {{! }} or {{ }} blocks, they will be accessible
  in later blocks.

  Included sub-templates receive the same instance of $s, so they have the 
  same $inref, etc. Thus, they can also set headers, change status, etc.

=head2 performance notes

  Templates are compiled into perl packages (or anonymous subroutines if
  there is no {{! }} block.) Caching of templates, which is on by default,
  will help speed performance greatly. The only reason you might want to
  turn it off is if you have many, many templates and don't want them 
  always kept around in memory.

  Preloading via preload() in a startup.pl file is a way to save more 
  memory (the template will get loaded before the webserver forks its
  children, thus keeping the template in memory shared by all the procs.)
  This also will improve speed a bit, as each newly spawned webserver
  proc will not need to load the template anew. 

  preload() may be used even with caching off (0), if you have a handful of
  templates you want to cache but many others you do not.

  Turning SimpleTemplateReload to off (0) will speed things a little bit,
  as SimpleTemplate will not check the file for updates with every request.
  However, if you are using caching/preloading and SimpleTemplateCache is 
  off (0), Apache must be restarted to see template changes.

  Finally, the regular CGI mode will probably be very slow, so you may
  want only to use it when testing something (a cached template or another
  module/subclass), or when using a host without mod_perl installed.

=head2 Note for users of previous versions 0.01 or 0.02
  
  Anyone switching from a version previous to 0.03 should note that the
  default {{ _perl_block_ }} behavior has changed. The behavior of the
  new {{: }} tag should be functionally equivalent, so switching all
  your tags to this should be an easy fix. (try 
  "perl -pi~ -e 's/\{\{/\{\{\:/g' __your_files__".)

  The imperfect backward-compatablility seemed worth it for the more
  intuitive behavior of the tags, and for the consistency with other
  templating mechanisms like jsp/asp.

  Note also the preferred $s->status(), $s->content_type() and
  $s->header() calls rather than $status, $content_type, $headerref.


=head1 VERSION

  Version 0.03, 2002-September-15.



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
