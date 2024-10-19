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

#define PARENT_OFFSET_BIT_COUNT 3
#define PARENT_OFFSET_BITS ((1 << PARENT_OFFSET_BIT_COUNT) - 1)

struct DensityNode
{
    DensityChild childs[8]; 
    uint parentIndex;
    uint parentOffsetAndDepth;
};
