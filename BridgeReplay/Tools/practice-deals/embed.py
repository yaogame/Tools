"""把 PracticeDeals.json 写成 Swift 源码，编进 App（不依赖资源打包）。"""
import json, os
here = os.path.dirname(os.path.abspath(__file__))
data = json.load(open(os.path.join(here, 'PracticeDeals.json')))
text = json.dumps(data, ensure_ascii=False, separators=(',', ':'))
assert '"#' not in text and '\\' not in text
out = os.path.join(here, '..', '..', 'BridgeReplay', 'Core', 'PracticeDealsData.swift')
with open(out, 'w') as f:
    f.write('// 由 Tools/practice-deals/embed.py 生成，不要手改。\n')
    f.write('let practiceDealsJSON = #"""\n' + text + '\n"""#\n')
print('wrote', out, len(text), 'bytes')
