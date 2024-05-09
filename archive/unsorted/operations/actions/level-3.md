% control(3) control
% Rodrigo Mesquita (romes)
% December 2021

# LEVEL 3 / ACTIONS

**level-3 / actions** is the third level abstraction of the control program and its associated controls / commands / actions. This page is associated with the directory ~/control/operations/actions.

# CONTROL

**control** currently can't access actions directly.

# OPERATIONS

**get_anki_ndue**
: program that prints out the number of cards due today in anki; *operates* by scraping ankiweb; *depends* on ankiweb.net/decks and an internet connection.

**get_things_ntoday**
: program that prints out the number of things due today; *operates* by querying Things3 through AppleScript; *depends* on Things3.
