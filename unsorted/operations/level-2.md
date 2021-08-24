% control(2) control
% Rodrigo Mesquita (romes)
% December 2021

# LEVEL 2 / OPERATIONS

**level-2 / operations** is the second level abstraction of the control program and its associated controls / commands / operations. This page is associated with the directory ~/control/operations.

# CONTROL

## GET

all keywords in this section must be preceeded by **get**.

**sentence** displays a sentence in a random language.

**report** displays a report with a new sentence, today's todos, anki due cards, and eventually a lot more.

# OPERATIONS

**sentences**
: program for printing, translating, and reading sentences - for practicing; *depends* on sentences stored in an sqlite database in ~/everything-else/languages.

**record**
: (WIP) {THIS OPERATION IS INCOMPLETE, AND I INTEND TO RE-WRITE AND EXPAND IT - MAYBE AS A LIBRARY FOR CONTROL TO USE}; program that prints out a status report; *depends* on level-3 actions **get_anki_ndue**, **get_things_ntoday**.
