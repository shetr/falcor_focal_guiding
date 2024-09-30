
import Utils.Math.AABB;

#define DESNITY_CHILD_SIZE (3 * 4)
#define DESNITY_CHILD_INDEX_OFFSET 0
#define DESNITY_CHILD_ACCUMULATOR_OFFSET 4
#define DESNITY_CHILD_DENSITY_OFFSET 8

#define DESNITY_NODE_SIZE (DESNITY_CHILD_SIZE * 8 + 2 * 4)
#define DESNITY_NODE_PARENT_INDEX_OFFSET DESNITY_CHILD_SIZE
#define DESNITY_NODE_PARENT_OFFSET_OFFSET (DESNITY_CHILD_SIZE + 4)

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
    uint parentIndex;
    uint parentOffset;
}

struct DensityNodes
{
    RWByteAddressBuffer nodes;

    uint getParentNodeIndex(uint nodeIndex)
    {
        return nodes.Load<uint>(nodeIndex * DESNITY_NODE_SIZE + DESNITY_NODE_PARENT_INDEX_OFFSET);
    }

    uint getParentNodeOffset(uint nodeIndex)
    {
        return nodes.Load<uint>(nodeIndex * DESNITY_NODE_SIZE + DESNITY_NODE_PARENT_OFFSET_OFFSET);
    }

    uint setParentNodeIndex(uint nodeIndex, uint parentNodeIndex)
    {
        nodes.Store(nodeIndex * DESNITY_NODE_SIZE + DESNITY_NODE_PARENT_INDEX_OFFSET, parentNodeIndex);
    }

    uint setParentNodeOffset(uint nodeIndex, uint childOffset)
    {
        nodes.Store(nodeIndex * DESNITY_NODE_SIZE + DESNITY_NODE_PARENT_OFFSET_OFFSET, childOffset);
    }

    bool isNodeRoot(uint nodeIndex)
    {
        return nodeIndex == 0;
    }

    DensityChild getChildNode(uint parentNodeIndex, uint childOffset)
    {
        uint childIndex = parentNodeIndex * DESNITY_NODE_SIZE + childOffset * DESNITY_CHILD_SIZE;
        DensityChild child;
        child.index = nodes.Load<uint>(childIndex + DESNITY_CHILD_INDEX_OFFSET);
        child.accumulator = nodes.Load<float>(childIndex + DESNITY_CHILD_ACCUMULATOR_OFFSET);
        child.density = nodes.Load<float>(childIndex + DESNITY_CHILD_DENSITY_OFFSET);
        return child;
    }

    void setChildNode(uint parentNodeIndex, uint childOffset, DensityChild child)
    {
        uint childIndex = parentNodeIndex * DESNITY_NODE_SIZE + childOffset * DESNITY_CHILD_SIZE;
        nodes.Store(childIndex + DESNITY_CHILD_INDEX_OFFSET, child.index);
        nodes.Store(childIndex + DESNITY_CHILD_ACCUMULATOR_OFFSET, child.accumulator);
        nodes.Store(childIndex + DESNITY_CHILD_DENSITY_OFFSET, child.density);
    }

    bool isChildNodeLeaf(uint parentNodeIndex, uint childOffset)
    {
        return getChildNodeIndex(parentNodeIndex, childOffset) == 0;
    }

    uint getChildNodeIndex(uint parentNodeIndex, uint childOffset)
    {
        int index = parentNodeIndex * DESNITY_NODE_SIZE + childOffset * DESNITY_CHILD_SIZE + DESNITY_CHILD_INDEX_OFFSET;
        return nodes.Load<uint>(index);
    }

    float getChildAccumulator(uint parentNodeIndex, uint childOffset)
    {
        int index = parentNodeIndex * DESNITY_NODE_SIZE + childOffset * DESNITY_CHILD_SIZE + DESNITY_CHILD_ACCUMULATOR_OFFSET;
        return nodes.Load<float>(index);
    }

    float getChildDensity(uint parentNodeIndex, uint childOffset)
    {
        int index = parentNodeIndex * DESNITY_NODE_SIZE + childOffset * DESNITY_CHILD_SIZE + DESNITY_CHILD_DENSITY_OFFSET;
        return nodes.Load<float>(index);
    }

    void setChildNodeIndex(uint parentNodeIndex, uint childOffset, uint value)
    {
        int index = parentNodeIndex * DESNITY_NODE_SIZE + childOffset * DESNITY_CHILD_SIZE + DESNITY_CHILD_INDEX_OFFSET;
        nodes.Store(index, value);
    }

    void setChildAccumulator(uint parentNodeIndex, uint childOffset, float value)
    {
        int index = parentNodeIndex * DESNITY_NODE_SIZE + childOffset * DESNITY_CHILD_SIZE + DESNITY_CHILD_ACCUMULATOR_OFFSET;
        nodes.Store(index, value);
    }

    void addToChildAccumulator(uint parentNodeIndex, uint childOffset, float value)
    {
        int index = parentNodeIndex * DESNITY_NODE_SIZE + childOffset * DESNITY_CHILD_SIZE + DESNITY_CHILD_ACCUMULATOR_OFFSET;
        nodes.InterlockedAddF32(index, value);
    }

    void setChildDensity(uint parentNodeIndex, uint childOffset, float value)
    {
        int index = parentNodeIndex * DESNITY_NODE_SIZE + childOffset * DESNITY_CHILD_SIZE + DESNITY_CHILD_DENSITY_OFFSET;
        nodes.Store(index, value);
    }
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

struct BoundedDensityAccumulator : IDensityAccumulator
{
    float densitiesSum;
    float minDensity;
    float maxDensity;

    __init(float min, float max)
    {
        densitiesSum = 0;
        minDensity = min;
        maxDensity = max;
    }

    [mutating]
    void addDensity(float density)
    {
        densitiesSum += density;
    }

    float getResult()
    {
        return (densitiesSum - minDensity) / (maxDensity - minDensity);
    }
}

#ifdef DENSITY_NODES_BLOCK
ParameterBlock<DensityNodes> gNodes;
void main() {}
#endif
