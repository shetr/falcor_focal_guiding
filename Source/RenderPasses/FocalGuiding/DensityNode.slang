
import Utils.Math.AABB;

struct DensityChild
{
    uint index;
    float accumulator;
    float density;

    bool isLeaf() {
        return index == 0;
    }
}

struct DensityNode
{
    DensityChild childs[8];
}

struct NodeTravRef
{
    uint node;
    uint child;

    __init(uint nodeIndex)
    {
        node = nodeIndex;
        child = 0;
    }
}

void travStackPushNode<let N : uint>(inout NodeTravRef stack[N], inout uint stackSize, NodeTravRef node)
{
    stack[stackSize] = node;
    ++stackSize;
}

void travStackPopNode(inout uint stackSize)
{
    --stackSize;
}

uint3 unpackOctreeChildIndex(uint index)
{
    int xi = index % 2;
    int yi = (index / 2) % 2;
    int zi = index / 4;
    return uint3(xi, yi, zi);
}

AABB shrinkBox(AABB box, uint3 axisIndices)
{
    AABB shrinkedBox;
    float3 halfExtent = box.extent() * 0.5;
    shrinkedBox.minPoint = box.minPoint + float3(axisIndices) * halfExtent;
    shrinkedBox.maxPoint = shrinkedBox.minPoint + halfExtent;
    return shrinkedBox;
}

AABB extendBox(AABB box, uint3 axisIndices)
{
    AABB extendedBox;
    float3 halfExtent = box.extent();
    extendedBox.minPoint = box.minPoint - float3(axisIndices) * halfExtent;
    extendedBox.maxPoint = extendedBox.minPoint + 2.0 * halfExtent;
    return extendedBox;
}
