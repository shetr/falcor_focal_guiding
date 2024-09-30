#pragma once
#include "Falcor.h"

using namespace Falcor;

struct DensityChild
{
    uint index;
    float accumulator;
    float density;

    bool isLeaf() { return index == 0; }
};

struct DensityNode
{
    DensityChild childs[8];
    uint parentIndex;
    uint parentOffset;
};
