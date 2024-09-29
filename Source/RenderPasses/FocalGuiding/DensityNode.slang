
import Utils.Math.AABB;
import Utils.Geometry.IntersectionHelpers;

#define DESNITY_CHILD_SIZE (3 * 4)
#define DESNITY_CHILD_INDEX_OFFSET 0
#define DESNITY_CHILD_ACCUMULATOR_OFFSET 4
#define DESNITY_CHILD_DENSITY_OFFSET 8

#define DESNITY_NODE_SIZE (DESNITY_CHILD_SIZE * 8)

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

struct DensityNodes
{
    RWByteAddressBuffer nodes;

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

struct NodeTraversal
{
    ParameterBlock<DensityNodes> nodes;
    uint nodesSize;
    RWByteAddressBuffer globalAccumulator;
    AABB initBox;

    __init(ParameterBlock<DensityNodes> _nodes, uint _nodesSize, RWByteAddressBuffer _globalAccumulator, AABB _initBox)
    {
        nodes = _nodes;
        nodesSize = _nodesSize;
        globalAccumulator = _globalAccumulator;
        initBox = _initBox;
    }

    void traverse(float3 rayOrigin, float3 rayDir, float3 hitPos) {
        float maxDensity = 0.0;
        float3 hitDir = hitPos - rayOrigin;
        float hitDist = length(hitDir);
        float rayLength = length(rayDir);

        NodeTravRef nodesStack[MAX_OCTREE_DEPTH];
        uint nodesStackSize = 0;
        // push first node
        nodesStack[nodesStackSize] = NodeTravRef(0);
        ++nodesStackSize;
        //AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);
        AABB box = initBox;
        uint failsafe = 0;
        while (nodesStackSize > 0 && failsafe < 9 * nodesSize)
        {
            uint topIndex = nodesStackSize - 1;
            if (nodesStack[topIndex].child >= 8) {
                // pop node
                --nodesStackSize;
                // correct the box
                if (nodesStackSize > 0) {
                    topIndex = nodesStackSize - 1;
                    uint currChildIndex = nodesStack[topIndex].child - 1;
                    int3 axisIndices = unpackOctreeChildIndex(currChildIndex);
                    box = extendBox(box, axisIndices);
                }
            }
            else
            {
                uint nodeIndex = nodesStack[topIndex].node;
                uint childIndex = nodesStack[topIndex].child;
                DensityChild child = nodes.getChildNode(nodeIndex, childIndex);
                int3 axisIndices = unpackOctreeChildIndex(childIndex);
                AABB childBox = shrinkBox(box, axisIndices);

                float2 nearFar;
                bool intersected = intersectRayAABB(rayOrigin, rayDir, childBox.minPoint, childBox.maxPoint, nearFar);
                if (intersected) {
                    float near = length(rayDir * nearFar.x);
                    float far = length(rayDir * nearFar.y);
                    if (near < hitDist) {
                        // TODO: visitChild function
                        if (!child.isLeaf() && nodesStackSize < MAX_OCTREE_DEPTH) {
                            box = childBox;
                            // push node
                            nodesStack[nodesStackSize] = NodeTravRef(child.index);
                            ++nodesStackSize;
                        }
                    }
                }

                ++nodesStack[topIndex].child;
            }
            ++failsafe;
        }
    }

}

//interface IDensityAccumulator
//{
//    [mutating]
//    void addDensity(float density);
//
//    float getResult();
//}



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
