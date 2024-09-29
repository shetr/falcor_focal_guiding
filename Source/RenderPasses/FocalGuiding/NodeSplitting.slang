import DensityNode;

ParameterBlock<DensityNodes> gNodes;
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

    for (int childIndex = 0; childIndex < 8; childIndex++)
    {
        DensityChild child = gNodes.getChildNode(nodeIndex, childIndex);
        // TODO: need to check max depth and max node count
        if (child.isLeaf() && child.density > gSplittingThreshold)
        {
            uint nodesSize = gNodesSize.Load<uint>(0);
            if (nodesSize < MAX_NODES_SIZE)
            {
                uint newNodeIndex;
                gNodesSize.InterlockedAdd(0, 1, newNodeIndex);
                if (newNodeIndex < MAX_NODES_SIZE)
                {
                    gNodes.setChildNodeIndex(nodeIndex, childIndex, newNodeIndex);
                    for (int ch = 0; ch < 8; ch++)
                    {
                        gNodes.setChildNodeIndex(newNodeIndex, ch, 0);
                        // put parent acc / 8
                        gNodes.setChildAccumulator(newNodeIndex, ch, 1.0);
                        gNodes.setChildDensity(newNodeIndex, ch, 1.0 / 8.0);
                    }
                }
                else
                {
                    gNodesSize.Store(0, MAX_NODES_SIZE);
                }
            }
        }
    }
}
