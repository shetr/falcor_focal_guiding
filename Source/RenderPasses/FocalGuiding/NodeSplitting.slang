import DensityNode;

ParameterBlock<DensityNodes> gNodes;
RWByteAddressBuffer gGlobalAccumulator;
RWByteAddressBuffer gNodesSize;

cbuffer CB
{
    float gSplittingThreshold;
}

[shader("compute")]
[numthreads(1,8,1)]
void computeMain(uint3 threadId : SV_DispatchThreadID)
{
    uint nodeIndex = threadId.x;
    uint childIndex = threadId.y;

    if (gNodes.isNodeRoot(nodeIndex))
    {
        return;
    }

    float invGlobalAcc = 1 / gGlobalAccumulator.Load<float>(0);

    if (!gNodes.isChildNodeLeaf(nodeIndex, childIndex))
    {
        return;
    }

    float accumulator = gNodes.getChildAccumulator(nodeIndex, childIndex);
    float densityTimesVolume = accumulator * invGlobalAcc;
    if (densityTimesVolume <= gSplittingThreshold)
    {
        return;
    }

    uint depth = gNodes.getNodeDepth(nodeIndex) + 1;
    if (depth >= MAX_OCTREE_DEPTH)
    {
        return;
    }

    uint newNodeIndex;
    gNodesSize.InterlockedAdd(0, 1, newNodeIndex);
    if (newNodeIndex < MAX_NODES_SIZE)
    {
        gNodes.setChildNodeIndex(nodeIndex, childIndex, newNodeIndex);
        gNodes.setParentNodeIndex(newNodeIndex, nodeIndex);
        gNodes.setParentNodeOffsetAndDepth(newNodeIndex, childIndex, depth);
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
