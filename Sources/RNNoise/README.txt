RNNoise v0.1.1 (https://github.com/xiph/rnnoise, tag v0.1.1) - licencja BSD, patrz COPYING.

Zmiany względem oryginału (FT710Control):
- src/rnn.c: dwie linie „*(int*)0=0;” (celowe zatrzymanie programu przy nieznanym typie aktywacji,
  nieosiągalne dla wbudowanego modelu) zamienione na „__builtin_trap();” - to samo działanie,
  bez ostrzeżenia nowszego kompilatora clang („Indirection of non-volatile null pointer will be deleted”).
Poza tym kod bez zmian.
