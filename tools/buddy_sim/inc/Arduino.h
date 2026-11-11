#pragma once
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <initializer_list>
using std::min; using std::max;
#define PI 3.14159265f
#define DEG_TO_RAD 0.017453292f
template<class T, class L, class H> T constrain(T v, L lo, H hi){ return v<lo?(T)lo:(v>hi?(T)hi:v); }
extern uint32_t simMillis;
inline uint32_t millis(){ return simMillis; }
inline long random(long n){ return rand()%n; }
