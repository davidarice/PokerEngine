// Prototypes for the vendored HenryRLee/PokerHandEvaluator 5-, 6- and 7-card
// high-hand evaluators (Apache-2.0, see THIRD_PARTY_NOTICES.md).
//
// Declared here instead of vendoring upstream's phevaluator.h so the module
// exposes only what PokerEngine uses: no PLO declarations, no C++ section.
//
// Card ids are rank * 4 + suit (ranks 2..A = 0..12, suits c, d, h, s = 0..3).
// The result is a hand class from 1 (royal flush) to 7462 (seven-high).

#ifndef CHANDEVALUATOR_H
#define CHANDEVALUATOR_H

int evaluate_5cards(int a, int b, int c, int d, int e);
int evaluate_6cards(int a, int b, int c, int d, int e, int f);
int evaluate_7cards(int a, int b, int c, int d, int e, int f, int g);

#endif
