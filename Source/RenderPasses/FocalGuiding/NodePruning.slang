import DensityNode;

ParameterBlock<DensityNodes> gNodes;
RWByteAddressBuffer gGlobalAccumulator;
RWByteAddressBuffer gNodesSize;

RWByteAddressBuffer gMaxDensities;
RWByteAddressBuffer gAvgDensities;

[shader("compute")]
[numthreads(1,1,1)]
void computeMain(uint3 threadId : SV_DispatchThreadID)
{
    uint nodeIndex = threadId.x;

    float invGlobalAcc = 1 / gGlobalAccumulator.Load<float>(0);
    uint nodeDepth = gNodes.getNodeDepth(nodeIndex) + 1;

    float invVolume = 1.0;
    for (uint depth = 0; depth <= MAX_OCTREE_DEPTH; depth++)
    {
        invVolume *= 8;
    }

    for (uint depth = MAX_OCTREE_DEPTH; depth > 0; depth--)
    {
        if (nodeDepth == depth)
        {
            float maxDensity = 0;
            float avgDensity = 0;
            for (int ch = 0; ch < 8; ++ch)
            {
                float childMaxDensity = 0;
                float childAvgDensity = 0;
                if (gNodes.isChildNodeLeaf(nodeIndex, ch))
                {
                    childMaxDensity = gNodes.getChildAccumulator(nodeIndex, ch) * invGlobalAcc * invVolume;
                    childAvgDensity = childMaxDensity;
                }
                else
                {
                    // read computed max/avg values
                    uint childIndex = gNodes.getChildNodeIndex(nodeIndex, ch);
                    childMaxDensity = gMaxDensities.Load<float>(childIndex);
                    childAvgDensity = gAvgDensities.Load<float>(childIndex);
                }
                maxDensity = max(maxDensity, childMaxDensity);
                avgDensity += childAvgDensity;
            }
            avgDensity *= (1.0 / 8.0);

            if (maxDensity <= 2 * avgDensity)
            {
                uint parentIndex = gNodes.getParentNodeIndex(nodeIndex);
                uint parentOffset = gNodes.getParentNodeOffset(nodeIndex);
                gNodes.setChildNodeToLeaf(parentIndex, parentOffset);
                // maybe we dont even need to decrease the gNodesSize
                //gNodesSize.InterlockedAdd(0, -8, newNodeIndex);
                // if we want to track deletions, then maybe add to another counter
            }
            else
            {
                // store computed max/avg values
                gMaxDensities.Store(nodeIndex, maxDensity);
                gAvgDensities.Store(nodeIndex, avgDensity);
            }
        }
        invVolume *= (1.0 / 8.0);
        AllMemoryBarrier();
    }
}
