/* libFuzzer port of tools/brt-fuzz.cpp: drives a REHex::ByteRangeTree through a sequence of
 * operations decoded from the input, relying on the tree's internal sanity checks
 * (REHEX_BYTERANGETREE_CHECKS) and the sanitizers to catch inconsistencies.
 *
 * Input: u32 address-space size, then one op per byte (plus operands as needed). Operands are
 * read little-endian and reduced modulo the valid domain; missing bytes read as zero.
*/

#include <memory>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <iterator>

/* Enable extra sanity checks (expensive) in ByteRangeTree. */
#define REHEX_BYTERANGETREE_CHECKS

#include "../src/ByteRangeTree.hpp"

static const off_t MAX_INITIAL_SPACE = 0x40000000; /* 1GiB */
static const unsigned MIN_ELEMENTS_BEFORE_DELETE = 4;

namespace
{
	struct Reader
	{
		const uint8_t *p;
		size_t n;
		
		bool empty() const { return n == 0; }
		
		uint32_t u8()
		{
			if(n == 0) { return 0; }
			--n;
			return *p++;
		}
		
		uint32_t u32()
		{
			uint32_t v = 0;
			for(int i = 0; i < 4; ++i) { v |= u8() << (i * 8); }
			return v;
		}
	};
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	if(size < 5)
	{
		return -1;
	}
	
	Reader in = { data, size };
	
	off_t current_space = 2 + (off_t)(in.u32() % (uint32_t)(MAX_INITIAL_SPACE - 2));
	bool delete_enabled = false;
	
	std::unique_ptr< REHex::ByteRangeTree<int> > tree(new REHex::ByteRangeTree<int>);
	
	auto random_range = [&]()
	{
		off_t begin = in.u32() % (current_space - 1);
		off_t end = begin + (in.u32() % (current_space - begin));
		
		return REHex::ByteRangeTreeKey(begin, end - begin);
	};
	
	auto random_node = [&]()
	{
		size_t idx = tree->size() >= 1
			? in.u32() % tree->size()
			: 0;
		
		return std::next(tree->begin(), idx);
	};
	
	while(!in.empty())
	{
		if(tree->size() >= MIN_ELEMENTS_BEFORE_DELETE)
		{
			delete_enabled = true;
		}
		
		int op = in.u8() % 100;
		
		/* Low chance of major ops (copy/assignment/clear) */
		
		if(op == 0)
		{
			REHex::ByteRangeTree<int> *new_tree = new REHex::ByteRangeTree<int>(*tree);
			tree.reset(new_tree);
		}
		else if(op == 1)
		{
			REHex::ByteRangeTree<int> *new_tree = new REHex::ByteRangeTree<int>;
			*new_tree = *tree;
			tree.reset(new_tree);
		}
		else if(op == 2)
		{
			tree->clear();
		}
		else{
			/* Distribute the remaining chance roughly equally between minor ops. */
			
			switch(op % 6)
			{
				case 0:
				case 1:
				{
					auto range = random_range();
					tree->set(range.offset, range.length, 0);
					break;
				}
				
				case 2:
				{
					if(tree->empty() || !delete_enabled) { break; }
					
					auto it = random_node();
					tree->erase(it);
					break;
				}
				
				case 3:
				{
					if(tree->empty() || !delete_enabled) { break; }
					
					auto it = random_node();
					tree->erase_recursive(it);
					break;
				}
				
				case 4:
				{
					auto range = random_range();
					tree->data_inserted(range.offset, range.length);
					break;
				}
				
				case 5:
				{
					auto range = random_range();
					tree->data_erased(range.offset, range.length);
					break;
				}
			}
		}
	}
	
	return 0;
}
