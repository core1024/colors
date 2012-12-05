#!/usr/bin/env perl

use strict;

use HTTP::Daemon;
use HTTP::Status;

use CAM::PDF;
use CAM::PDF::PageText;
use MIME::Base64;

use constant HTTP_HOST => '127.0.0.1';
use constant HTTP_PORT => 8888;
use constant DEFAULT_SPEED => 18;

use constant APP_VER => '5';

my $html_header = <<HTML;
<!DOCTYPE html>
<html lang="bg">
<head>
	<meta charset="utf-8">
	<title>Обработка на цветове</title>
	<meta name="description" content="The HTML5 Herald">
	<meta name="author" content="Vladimir Borisov">
</head>
<body style="background-color:ButtonFace;">
HTML
my $html_frame = <<HTML;
	<iframe src="about:blank" id="ifu" style="width:0;height:0;position:absolute;top:-1000px;"></iframe>
	<script type="text/javascript">
	(function(d) {
		var ifu = document.getElementById('ifu');
		ifu = (ifu.contentWindow) ? ifu.contentWindow : (ifu.contentDocument.document) ? ifu.contentDocument.document : ifu.contentDocument;
		ifu.document.open();
		ifu.document.write('<form id="upload-form" action="" method="post" enctype="multipart/form-data" target="_top"><input type="file" name="colors" id="colors"></form>');
		ifu.document.close();
		var colors = ifu.document.getElementById('colors');
		colors.onchange = function() {
			ifu.document.getElementById('upload-form').submit();
		};
		ifu.document.getElementById('upload-form').onsubmit = function() {
			if(! colors.value) {
				colors.click();
				return false;
			}
		};
		document.getElementById('feed').onclick = function(){
			colors.click();
		};
	})(document);
	</script>
HTML
my $html_footer = <<'HTML';
</body>
</html>
HTML

my %color_map = ('Black', 1, 'Cyan', 2, 'Magenta', 3, 'Yellow', 4);
#my %color_sp = ('Black', 0x0e, 'Cyan', 0x14, 'Magenta', 0x10, 'Yellow', 0x16);
my %color_sp = ('Black', 0x07, 'Cyan', 0x0a, 'Magenta', 0x8, 'Yellow', 0x0b);

my $d = HTTP::Daemon->new(LocalAddr => HTTP_HOST, LocalPort => HTTP_PORT, Reuse => 1);

die "can't setup server" unless $d;

print "Server started at ".$d->url."\n";

while (my $c = $d->accept) {
	while (my $r = $c->get_request) {
# Upload form
		unless($r->url->query or $r->method eq 'POST') {
			my $h = <<HTML;
			$html_header
	<div style="text-align: center;">
		<input type="submit" value="Качи PDF" id="feed" style="font-size: 2em;margin-top:1em;"/>
	</div>
	$html_frame
	$html_footer
HTML
			my $rs = new HTTP::Response;
			$rs->header('Content-Type' => 'text/html');
			$rs->content($h);
			$c->send_response($rs);
			$c->close;
			goto LAST;

# Generateing the .ry4 file
		} elsif($r->url->query) {
			my $tra_la_la = '';
			my %query = split /[=&]/, $r->url->query;
			my %colors = (); # data for colors
			my @cids = ();
			my $colidx = ''; # index of colors
			unless ($query{'f'}) {
				$c->send_redirect("/");
				goto LAST;
			}
			
			foreach (keys %query) {
				next if /(-speed$|-index$|^f$)/;
				my $key = lc $_;
				unless ($query{$key.'-index'} and $query{$key.'-speed'}) {
					$c->send_redirect("/");
					goto LAST;
				}
				$colidx .= pack 'C', $color_map{$_} ? $color_map{$_} : $query{$key.'-index'};
				$colors{$_} = $query{$_};
				# Unescape the URL
				$colors{$_} =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
				# Decode
				$colors{$_} = decode_base64 $colors{$_};

				# Test if valid
				if (length $colors{$_} != 46) {
					$c->send_redirect("/");
					goto LAST;
				}

				# Add speed
				$colors{$_} = pack 'a194ss', $colors{$_}, 0x0a, $query{$key.'-speed'} * 2;
				push @cids, $_;
			}
			unless (@cids and ! ($colidx =~ /(.).*\1/)) {
				$c->send_redirect("/");
				goto LAST;
			}

			my $template = pack 'a16a4784a6a2', '000023 RAMP BAND', $colidx, 'V1.01','UU';

			my $offset = 0x30;
			my $step = 0xc6;
			foreach (@cids) {
				substr($template, $offset, $step) = $colors{$_};
				$offset+=$step;
			}
			my $rs = new HTTP::Response;
			$rs->header("Cache-Control" => "public");
			$rs->header("Content-Description" => "File Transfer");
			$rs->header("Content-Disposition" => "attachment; filename=$query{'f'}.ry4");
			$rs->header("Content-Type" => "application/octet-stream");
			$rs->header("Content-Transfer-Encoding" => "binary");
			$rs->content($template);
			$c->send_response($rs);
			$c->close;
			goto LAST;
		}

# Parsing the PDF
		my $input = $r->content;
		my @secs = split /\r\n\r\n/, $input;

		my %headers = (shift(@secs) =~ m/\n([^:]+): (.*)(?:\r|$)/g);

# Headers validation
		unless ($headers{'Content-Type'} eq 'application/pdf' and $headers{'Content-Disposition'}) {
			$c->send_redirect("/");
			goto LAST;
		}

# File validation
		my $doc;
		unless ($doc = CAM::PDF->new(shift(@secs)))
		{
			$c->send_redirect("/");
			goto LAST;
		}

		(my $filename) = ($headers{'Content-Disposition'} =~ m/filename="(.+).pdf"/i);

		my $html_body = '';
		my $color_index = 5;

		foreach my $p ( 2 .. $doc->numPages()) {
			my $str = $doc->getPageText($p);

			my @row = split /\n/, $str;
			my @cols;
			my $values = '';
			my $max;
			foreach (26 .. 48) {
				my $val = $row[$_]*4;
				push @cols, $val;
				$max = $val unless $max > $val;
				$values .= pack 's', $val;
			}

			# Na nula ne se deli, taka che ni trqbva neshto blizko
			$max = .0000000000000000000000000001 unless ($max);

			(my $color) = ($row[0] =~ /- (.*?) Layer/);

			$values = encode_base64 $values;
			chop $values;
			my $checked = defined $color_map{$color} ? ' checked=checked' : '';
			$html_body .= <<HTML;
		<tr>
			<td><input type="checkbox"$checked name="$color" id="$color" value="$values"/><label unselectable="on" for="$color">$color</label></td>
			<td><table style="display:inline-table;background-color:lightgray;height:1.3em;"><tr>
HTML

			$html_body .= sprintf <<'HTML', $_/4, $_, defined $color_map{$color} ? $color : 'darkgray', ($_ / $max) foreach (@cols); 
					<td style="vertical-align:bottom;height=1em;" title="%d, (hex*4 0x%04x)">
						<div style="cursor:default;background-color:%s;height:%fem">&nbsp;</div>
					</td>
HTML

			$html_body .= sprintf <<'HTML', lc $color, $color_sp{$color} ? $color_sp{$color} : DEFAULT_SPEED;
			</tr></table>
			</td>
			<td>
				<label unselectable="on" for="%s-speed">Скорост</label>
				<input type="number" size="6" id="%1$s-speed" name="%1$s-speed" value="%d"/>
			</td>
HTML
			$html_body .= sprintf <<'HTML', lc $color, $color_map{$color} ? ' readonly="readonly"' : '', $color_map{$color} ? $color_map{$color} : $color_index++;
			<td>
				<label unselectable="on" for="%s-index">Индекс</label>
				<input type="number" size="6" id="%1$s-index" name="%1$s-index"%s value="%d"/>
			</td>
		</tr>
HTML
		}
		$c->send_redirect("/") and goto LAST unless $html_body;

		my $h = sprintf <<'HTML', $html_header, $filename, $html_body, APP_VER, $html_frame, $html_footer;
%s
	<style>
label {
	-webkit-touch-callout: none;
	-webkit-user-select: none;
	-khtml-user-select: none;
	-moz-user-select: none;
	-ms-user-select: none;
	user-select: none;
}
[readonly="readonly"], [readonly] {
	color: gray;
}
	</style>
	<form method="get" action="" id="upload-form">
		<input type="hidden" name="f" value="%s"/>
		<table style="margin: 2em auto;background-color: ButtonHighlight; box-shadow: 0 0 1em;">
			<tr>
				<td colspan="4">
					<h1 style="text-align: center;">%2$s.pdf</h1><hr/>
				</td>
			</tr>
%s
			<tr>
				<td colspan="4">
					<table style="width: 100%;"><tr>
					<td width="50%">
						<button type="button" style="font-size:1.2em;width: 100%;" id="feed">Качи PDF</button>
					</td><td width="50%">
						<button type="submit" style="font-size:1.2em; width: 100%;">Изтегли</button>
					</td>
					</tr></table>
				</td>
			</tr>
			<tr>
				<td colspan="4" style="text-align: right;"><small>вер. %s</small></td>
			</tr>
		</table>
	</form>
%s
	<script type="text/javascript">
	(function(d, foreach) {
		if (! d.querySelectorAll || ! foreach) return;
		var maxchecked = 6
			, totalchecked = 0;
		foreach.call(d.querySelectorAll('input[type=checkbox]'), function(el) {
			totalchecked += el.checked;
			el.onclick = function() {
				totalchecked += el.checked ? 1 : -1;
				foreach.call(d.querySelectorAll('input[type=checkbox]:not(:checked)'), function(en) {
					en.disabled = totalchecked >= maxchecked;
				});
			}
		});
		if(typeof(Storage)==="undefined") return;
		foreach.call(d.querySelectorAll('input[type=number][id$=speed]'), function(el) {
			if(typeof localStorage[el.id] !== 'undefined') el.value = localStorage[el.id];
		});
		d.getElementById('upload-form').onsubmit = function() {
			foreach.call(d.querySelectorAll('input[type=number][id$=speed]'), function(el) {
				localStorage[el.id] = el.value;
			});
		}
	})(document, Array.prototype.forEach);
	</script>
%s
HTML
		my $rs = new HTTP::Response;
		$rs->header('Content-Type' => 'text/html');
		$rs->content($h);
		$c->send_response($rs);
		goto LAST;
	}
	LAST:
	$c->close;
	undef($c);
}
