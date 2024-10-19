import DensityNode;

ParameterBlock<DensityNodes> gNodes;
RWByteAddressBuffer gGlobalAccumulator;
RWByteAddressBuffer gNodesSize;

cbuffer CB
{
    float gSplittingThreshold;
}

[shader("compute")]
[numthreads(1,1,1)]
void computeMain(uint3 threadId : SV_DispatchThreadID)
{
    uint nodeIndex = threadId.x;

    uint nodesSize = gNodesSize.Load<uint>(0);
    if (gNodes.isNodeRoot(nodeIndex) || nodeIndex >= nodesSize)
    {
        return;
    }

    float invGlobalAcc = 1 / gGlobalAccumulator.Load<float>(0);

    for (int childIndex = 0; childIndex < 8; childIndex++)
    {
        if (nodesSize >= MAX_NODES_SIZE)
        {
            return;
        }

        if (!gNodes.isChildNodeLeaf(nodeIndex, childIndex))
        {
            continue;
        }

        float accumulator = gNodes.getChildAccumulator(nodeIndex, childIndex);
        float densityTimesVolume = accumulator * invGlobalAcc;
        if (densityTimesVolume <= gSplittingThreshold)
        {
            continue;
        }

        uint depth = 0;
        uint parentOffset = childIndex;
        uint parentIndex = nodeIndex;
        do
        {
            parentOffset = gNodes.getParentNodeOffset(parentIndex);
            parentIndex = gNodes.getParentNodeIndex(parentIndex);
            depth += 1;
        } while (!gNodes.isNodeRoot(parentIndex));

        if (depth >= MAX_OCTREE_DEPTH)
        {
            continue;
        }
        uint newNodeIndex;
        gNodesSize.InterlockedAdd(0, 1, newNodeIndex);
        if (newNodeIndex < MAX_NODES_SIZE)
        {
            gNodes.setChildNodeIndex(nodeIndex, childIndex, newNodeIndex);
            gNodes.setParentNodeIndex(newNodeIndex, nodeIndex);
            gNodes.setParentNodeOffset(newNodeIndex, childIndex);
            for (int ch = 0; ch < 8; ch++)
            {
                gNodes.setChildNodeIndex(newNodeIndex, ch, 0);
                gNodes.setChildAccumulator(newNodeIndex, ch, accumulator / 8.0);
            }
        }
        else
        {
            gNodesSize.Store(0, MAX_NODES_SIZE);
        }
    }
}
