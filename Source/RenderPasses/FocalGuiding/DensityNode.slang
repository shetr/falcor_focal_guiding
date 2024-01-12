
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

interface IDensityAccumulator
{
    [mutating]
    void addDensity(float density);

    float getResult();
}

struct MaxDensityAccumulator : IDensityAccumulator
{
    float maxDensity;

    __init()
    {
        maxDensity = 0;
    }

    [mutating]
    void addDensity(float density)
    {
        maxDensity = max(density, maxDensity);
    }

    float getResult()
    {
        return maxDensity;
    }
}

struct AvgDensityAccumulator : IDensityAccumulator
{
    float densitiesSum;
    uint densitiesCount;

    __init()
    {
        densitiesSum = 0;
        densitiesCount = 0;
    }

    [mutating]
    void addDensity(float density)
    {
        densitiesSum += density;
        densitiesCount++;
    }

    float getResult()
    {
        if (densitiesCount > 0) {
            return densitiesSum / (float)densitiesCount;
        }
        return 0;
    }
}

struct SumDensityAccumulator : IDensityAccumulator
{
    float densitiesSum;

    __init()
    {
        densitiesSum = 0;
    }

    [mutating]
    void addDensity(float density)
    {
        densitiesSum += density;
    }

    float getResult()
    {
        return densitiesSum;
    }
}
