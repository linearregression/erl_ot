# Intro

This is operational transformation (OT) library for Erlang. Almost complete port of js lib [changesets](https://github.com/marcelklehr/changesets) by [Marcel Klehr](https://github.com/marcelklehr). You can start with reading his great doc about OT.

# Usage

	Text = <<"Hello adventurer!">>,
	TextA = <<"Hello treasured adventurer!">>,
	TextB = <<"Good day adventurers, y'all!">>,
	
	% js: ch.text.constructChangeset(text, textA).pack()
	ChA = ot:unpack(<<"+6:h:treasured :0">>),
	
	% js: ch.text.constructChangeset(text, textB).pack()
	ChB = ot:unpack(<<"-0:h:Hell:0+4:h:G:0+5:h:od day:0+g:h:s, y'all:0">>),
	
	TextA = ot:apply_to(ChA, Text),
	TextB = ot:apply_to(ChB, Text),
	
	% Mutate change B through change A
	ChBA = ot:transform(ChB, ChA),
	
	% Got merged version of text
	<<"Good day treasured adventurers, y'all!">> = ot:apply_to(ChBA, TextA).	

# License
MIT
