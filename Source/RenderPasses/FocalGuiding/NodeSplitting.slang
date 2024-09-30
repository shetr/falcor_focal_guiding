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

    if (gNodes.isNodeRoot(nodeIndex))
    {
        return;
    }

    for (int childIndex = 0; childIndex < 8; childIndex++)
    {
        uint nodesSize = gNodesSize.Load<uint>(0);
        if (nodesSize >= MAX_NODES_SIZE)
        {
            return;
        }
        DensityChild child = gNodes.getChildNode(nodeIndex, childIndex);
        if (!child.isLeaf())
        {
            continue;
        }

        uint depth = 0;
        float density = child.density;
        uint parentIndex = nodeIndex;
        uint parentOffset = childIndex;
        do
        {
            parentIndex = gNodes.getParentNodeIndex(parentIndex);
            parentOffset = gNodes.getParentNodeOffset(parentIndex);
            density *= gNodes.getChildDensity(parentIndex, parentOffset);
            depth += 1;
        } while (!gNodes.isNodeRoot(parentIndex));

        if (density <= gSplittingThreshold || depth >= MAX_OCTREE_DEPTH)
        {
            continue;
        }
        float parentAccumulator = gNodes.getChildAccumulator(gNodes.getParentNodeIndex(nodeIndex), gNodes.getParentNodeOffset(nodeIndex));
        uint newNodeIndex;
        gNodesSize.InterlockedAdd(0, 1, newNodeIndex);
        if (newNodeIndex < MAX_NODES_SIZE)
        {
            gNodes.setChildNodeIndex(nodeIndex, childIndex, newNodeIndex);
            // TODO: add parent indices
            for (int ch = 0; ch < 8; ch++)
            {
                gNodes.setChildNodeIndex(newNodeIndex, ch, 0);
                gNodes.setChildAccumulator(newNodeIndex, ch, parentAccumulator / 8.0);
                gNodes.setChildDensity(newNodeIndex, ch, 1.0 / 8.0);
            }
        }
        else
        {
            gNodesSize.Store(0, MAX_NODES_SIZE);
        }
    }
}
